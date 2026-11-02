import CryptoKit
import Photos
import UIKit

/// A problem that would fail every remaining file too, so the run stops rather than churning through iCloud downloads.
private struct StopRun: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FileRejected: LocalizedError {
    let code: Int
    var errorDescription: String? { "The laptop rejected this file (\(code))." }
}

@MainActor
final class Uploader: ObservableObject {
    @Published var running = false
    @Published var status = "Ready"
    @Published var total = 0
    @Published var checked = 0
    @Published var uploaded = 0
    @Published var bytes: Int64 = 0
    @Published var failed = 0
    @Published var lastError: String?

    private var task: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true // ride out Wi-Fi handoffs while walking around
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config)
    }()

    func start(server: String) {
        guard !running, let base = URL(string: server.trimmingCharacters(in: .whitespaces)) else { return }
        running = true
        (checked, uploaded, bytes, failed, total) = (0, 0, 0, 0, 0)
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                try await run(base: base)
                status = failed == 0 ? "Finished: everything is on the laptop" : "Finished with \(failed) failed. Tap Start to retry them."
            } catch is CancellationError {
                status = "Stopped. Tap Start to continue."
            } catch {
                status = "Paused. Tap Start to continue."
                lastError = error.localizedDescription
            }
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func stop() { task?.cancel() }

    private func run(base: URL) async throws {
        status = "Asking for photo access…"
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            throw StopRun(message: "PhotoDrop needs Full Access: Settings > Privacy & Security > Photos > PhotoDrop.")
        }
        status = "Comparing with the laptop…"
        var done = Set(try await fetchManifest(base: base))

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // newest months first
        let assets = PHAsset.fetchAssets(with: options)
        total = assets.count

        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            for resource in PHAssetResource.assetResources(for: asset) where Self.wanted.contains(resource.type) {
                let path = Self.remotePath(
                    id: asset.localIdentifier, date: asset.creationDate ?? .distantPast, filename: resource.originalFilename)
                if done.contains(path) { continue }
                status = "Sending \(resource.originalFilename)"
                do {
                    try await upload(resource, to: path, mtime: asset.creationDate ?? .distantPast, base: base)
                    done.insert(path)
                    uploaded += 1
                } catch let error as StopRun {
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError {
                    try Task.checkCancellation() // Stop cancels the request; that isn't a lost connection
                    throw StopRun(message: "Lost the laptop: \(error.localizedDescription)")
                } catch {
                    failed += 1
                    lastError = "\(resource.originalFilename): \(error.localizedDescription)"
                }
            }
            checked = index + 1
        }
    }

    /// Originals plus any edited versions. Thumbnails and internal edit data are skipped.
    private static let wanted: Set<PHAssetResourceType> = [
        .photo, .alternatePhoto, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo, .audio,
    ]

    /// Must be stable between runs or everything re-uploads, hence UTC and the identifier hash.
    /// The shared prefix keeps a Live Photo's HEIC and MOV next to each other.
    nonisolated static func remotePath(id: String, date: Date, filename: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d%02d%02d_%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        let hash = SHA256.hash(data: Data(id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let safe = String(filename.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
        return String(format: "%04d/%02d/", c.year!, c.month!) + "\(stamp)_\(hash)_\(safe)"
    }

    private func fetchManifest(base: URL) async throws -> [String] {
        let (data, response) = try await session.data(from: base.appendingPathComponent("manifest"))
        try Self.check(response)
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func upload(_ resource: PHAssetResource, to path: String, mtime: Date, base: URL) async throws {
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

        var components = URLComponents(url: base.appendingPathComponent("file"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "sha256", value: try await Self.sha256(of: file)),
            URLQueryItem(name: "mtime", value: String(mtime.timeIntervalSince1970)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        let (_, response) = try await session.upload(for: request, fromFile: file)
        try Self.check(response)
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        bytes += Int64(size ?? 0)
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return
        case 403: throw StopRun(message: "The laptop refused this device. Is the iPhone signed in to your own tailnet?")
        case 507: throw StopRun(message: "The laptop's disk is nearly full.")
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
