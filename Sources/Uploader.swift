import CryptoKit
import Photos
import UIKit
import UniformTypeIdentifiers

/// A problem that would fail every remaining file too, so the run stops rather than churning through iCloud downloads.
private struct StopRun: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FileRejected: LocalizedError {
    let code: Int
    var errorDescription: String? { "The laptop rejected this file (\(code))." }
}

struct Manifest: Decodable {
    let verified: [String]
    let holding: [String]
    let archive: [String]
    let archive_indexed: Bool
    let desktop_online: Bool
    let holding_bytes: Int64
    let move_error: String?
    let laptop_free_bytes: Int64
}

private struct PutReply: Decodable {
    let key: String
    let state: String
}

struct Media: Identifiable {
    let asset: PHAsset
    let resources: [PHAssetResource]
    let month: String
    var id: String { asset.localIdentifier }
    var filename: String { resources.first?.originalFilename ?? "" }
    var isVideo: Bool { asset.mediaType == .video }
    var isRaw: Bool {
        resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
    }
    var size: Int64 { resources.compactMap(Uploader.size(of:)).reduce(0, +) }
}

enum MediaState { case pending, laptop, desktop }

@MainActor
final class Uploader: ObservableObject {
    @Published var media: [Media] = []
    @Published var manifest: Manifest?
    @Published var selected: Set<String> = []
    @Published var failed: [String: String] = [:]
    @Published var running = false
    @Published var scanning = false
    @Published var status = "Ready"
    @Published var batchDone = 0
    @Published var batchTotal = 0
    @Published var bytes: Int64 = 0
    @Published var lastError: String?

    private var desktopKeys = Set<String>()
    private var laptopKeys = Set<String>()
    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true // ride out Wi-Fi handoffs while walking around
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config)
    }()

    // MARK: Library

    /// Originals plus any edited versions. Thumbnails and internal edit data are skipped.
    private nonisolated static let wanted: Set<PHAssetResourceType> = [
        .photo, .alternatePhoto, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo, .audio,
    ]

    func loadLibrary() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        status = "Reading your photo library…"
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            status = "PhotoDrop needs Full Access: Settings > Privacy & Security > Photos > PhotoDrop."
            return
        }
        media = await Task.detached(priority: .userInitiated) { Self.scanLibrary() }.value
        status = "Ready"
    }

    private nonisolated static func scanLibrary() -> [Media] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // newest months first
        let assets = PHAsset.fetchAssets(with: options)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMM"
        var result: [Media] = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset).filter { wanted.contains($0.type) }
            guard !resources.isEmpty else { return }
            let date = asset.creationDate ?? asset.modificationDate ?? Date()
            result.append(Media(asset: asset, resources: resources, month: formatter.string(from: date)))
        }
        return result
    }

    /// PhotoKit has no public file size. Without it a file just gets sent, and the laptop spots the duplicate.
    nonisolated static func size(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: Selector(("fileSize"))) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// The original filename, except edited versions, which all arrive named "FullSizeRender".
    nonisolated static func remoteName(_ resource: PHAssetResource, in resources: [PHAssetResource]) -> String {
        var name = resource.originalFilename
        if resource.type == .fullSizePhoto || resource.type == .fullSizeVideo || resource.type == .fullSizePairedVideo {
            let base = resources.first { $0.type == .photo || $0.type == .video }?.originalFilename ?? name
            name = (base as NSString).deletingPathExtension + "_edited." + (name as NSString).pathExtension
        }
        return safeName(name)
    }

    nonisolated static func safeName(_ name: String) -> String {
        String(name.map { "\\/:*?\"<>|".contains($0) || $0.isNewline ? "_" : $0 })
    }

    private func key(_ resource: PHAssetResource, in media: Media) -> String? {
        Self.size(of: resource).map { "\(Self.remoteName(resource, in: media.resources).lowercased())|\($0)" }
    }

    func state(of item: Media) -> MediaState {
        let keys = item.resources.map { key($0, in: item) }
        if keys.allSatisfy({ $0.map(desktopKeys.contains) == true }) { return .desktop }
        if keys.allSatisfy({ $0.map { desktopKeys.contains($0) || laptopKeys.contains($0) } == true }) { return .laptop }
        return .pending
    }

    // MARK: Laptop

    func refresh(server: String) async {
        guard let base = URL(string: server.trimmingCharacters(in: .whitespaces)), base.host != nil else { return }
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("manifest"))
            try Self.check(response)
            let latest = try JSONDecoder().decode(Manifest.self, from: data)
            manifest = latest
            desktopKeys = Set(latest.verified).union(latest.archive)
            laptopKeys = Set(latest.holding)
            if !running { lastError = nil }
        } catch {
            manifest = nil
            if !running { lastError = "Can't reach the laptop: \(error.localizedDescription)" }
        }
    }

    // MARK: Sending

    func start(server: String, ids: Set<String>, limit: Int) {
        guard !running, let base = URL(string: server.trimmingCharacters(in: .whitespaces)) else { return }
        running = true
        lastError = nil
        bytes = 0
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                await refresh(server: server)
                guard manifest != nil else { throw StopRun(message: lastError ?? "Can't reach the laptop.") }
                try await run(base: base, ids: ids, limit: limit)
                status = failed.isEmpty ? "Batch finished" : "Batch finished with \(failed.count) failed"
            } catch is CancellationError {
                status = "Stopped. Nothing is lost: send again to continue."
            } catch {
                status = "Paused. Send again to continue."
                lastError = error.localizedDescription
            }
            await refresh(server: server)
            selected.subtract(media.filter { state(of: $0) != .pending }.map(\.id))
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func stop() { task?.cancel() }

    private func run(base: URL, ids: Set<String>, limit: Int) async throws {
        var queue: [(Media, PHAssetResource)] = []
        for item in media where ids.contains(item.id) {
            for resource in item.resources {
                let known = key(resource, in: item).map { desktopKeys.contains($0) || laptopKeys.contains($0) } ?? false
                if !known { queue.append((item, resource)) }
            }
        }
        // A Live Photo's two halves count as one batch step so a limit never splits a pair.
        var kept: [(Media, PHAssetResource)] = []
        var fileCount = 0
        var lastId: String?
        for entry in queue {
            if entry.0.id != lastId, fileCount >= limit { break }
            lastId = entry.0.id
            kept.append(entry)
            fileCount += 1
        }
        batchDone = 0
        batchTotal = kept.count
        for (item, resource) in kept {
            try Task.checkCancellation()
            status = "Sending \(resource.originalFilename)"
            do {
                try await upload(resource, of: item, base: base)
                failed[item.id] = nil
            } catch let error as StopRun {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                try Task.checkCancellation() // Stop cancels the request; that isn't a lost connection
                throw StopRun(message: "Lost the laptop: \(error.localizedDescription)")
            } catch {
                failed[item.id] = error.localizedDescription
                lastError = "\(resource.originalFilename): \(error.localizedDescription)"
            }
            batchDone += 1
        }
    }

    private func upload(_ resource: PHAssetResource, of item: Media, base: URL) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }

        // writeData hands back the stored bytes untouched, and fetches from iCloud when needed.
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }

        let date = item.asset.creationDate ?? item.asset.modificationDate ?? Date()
        var components = URLComponents(url: base.appendingPathComponent("file"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: Self.remoteName(resource, in: item.resources)),
            URLQueryItem(name: "month", value: item.month),
            URLQueryItem(name: "sha256", value: try await Self.sha256(of: file)),
            URLQueryItem(name: "mtime", value: String(date.timeIntervalSince1970)),
        ]
        // URLComponents leaves "+" alone, and the server would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try Self.check(response)
        let reply = try JSONDecoder().decode(PutReply.self, from: data)
        if reply.state == "holding" { laptopKeys.insert(reply.key) } else { desktopKeys.insert(reply.key) }
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        bytes += Int64(size ?? 0)
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return
        case 403: throw StopRun(message: "The laptop refused this device. Is the iPhone signed in to your own tailnet?")
        case 507: throw StopRun(message: "The laptop's disk is nearly full. It frees up as files reach the desktop.")
        case 500...: throw StopRun(message: "The laptop reported an error (\(code)). Is the receiver running?")
        default: throw FileRejected(code: code) // e.g. a checksum mismatch: only this file failed
        }
    }

    private nonisolated static func sha256(of file: URL) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
