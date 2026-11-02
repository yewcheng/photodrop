import BackgroundTasks
import CryptoKit
import Network
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
    let destination: String
    let holding_bytes: Int64
    let move_error: String?
    let laptop_free_bytes: Int64
}

struct HistoryRow: Decodable, Identifiable {
    let key: String
    let name: String
    let size: Int64
    let state: String
    let dest_path: String?
    let received_at: Double
    let verified_at: Double?
    let error: String?
    var id: String { key }
}

private struct PutReply: Decodable {
    let key: String
    let state: String
}

/// What the app remembers about one library item. Saved between launches, because
/// reading names and sizes from iOS takes minutes across a whole library.
struct Media: Identifiable, Codable {
    let id: String
    let modified: Date?
    let created: Date?
    let month: String
    let filename: String
    let isVideo: Bool
    let isRaw: Bool
    let keys: [String?]
    let sizes: [Int64?]
    var size: Int64 { sizes.compactMap { $0 }.reduce(0, +) }
}

enum MediaState { case pending, laptop, desktop }

@MainActor
final class Uploader: ObservableObject {
    static let shared = Uploader()
    static let backgroundTaskId = "com.photodrop.backup.process"

    @Published var media: [Media] = [] { didSet { months = Self.groupByMonth(media) } }
    @Published private(set) var months: [(month: String, items: [Media])] = []
    @Published private(set) var counts: [MediaState: Int] = [:]
    @Published var manifest: Manifest?
    @Published var history: [HistoryRow] = []
    @Published var selected: Set<String> = []
    @Published var failed: [String: String] = [:]
    @Published var running = false
    @Published var scanning = false
    @Published var status = "Ready"
    @Published var batchDone = 0
    @Published var batchTotal = 0
    @Published var bytesDone: Int64 = 0
    @Published var bytesTotal: Int64 = 0
    @Published var batchStarted = Date()
    @Published var lastError: String?
    @Published private(set) var onWiFi = false

    private var desktopKeys = Set<String>()
    private var laptopKeys = Set<String>()
    private var task: Task<Void, Never>?
    private var stoppedByUser = false
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi) // tells Wi-Fi apart even with Tailscale's VPN on
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true // ride out Wi-Fi handoffs while walking around
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config)
    }()

    private init() {
        UserDefaults.standard.register(defaults: ["wifiOnly": true, "batchLimit": 500])
        UIDevice.current.isBatteryMonitoringEnabled = true
        wifiMonitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in Uploader.shared.onWiFi = available }
        }
        wifiMonitor.start(queue: .global(qos: .utility))
    }

    private var server: String { UserDefaults.standard.string(forKey: "serverURL") ?? "" }
    private var baseURL: URL? {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.host != nil else { return nil }
        return url
    }

    // MARK: Library

    /// Originals plus any edited versions. Thumbnails and internal edit data are skipped.
    private nonisolated static let wanted: Set<PHAssetResourceType> = [
        .photo, .alternatePhoto, .fullSizePhoto, .video, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo, .audio,
    ]

    private nonisolated static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("library.json")
    }

    private nonisolated static func saveCache(_ media: [Media]) {
        if let data = try? JSONEncoder().encode(media) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// Shows the saved list straight away, then catches up with whatever changed since.
    func loadLibrary() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        if media.isEmpty {
            let cached = await Task.detached(priority: .userInitiated) { () -> [Media] in
                guard let data = try? Data(contentsOf: Self.cacheURL) else { return [] }
                return (try? JSONDecoder().decode([Media].self, from: data)) ?? []
            }.value
            if !cached.isEmpty {
                media = cached
                updateCounts()
            }
        }
        guard await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized else {
            status = "PhotoDrop needs Full Access: Settings > Privacy & Security > Photos > PhotoDrop."
            return
        }
        let known = Dictionary(media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if known.isEmpty { status = "Reading your photo library for the first time…" }
        media = await Task.detached(priority: .utility) {
            Self.scanLibrary(known: known) { done, total in
                Task { @MainActor in Uploader.shared.status = "Reading your photo library: \(done) of \(total) new items" }
            }
        }.value
        updateCounts()
        if !running { status = "Ready" }
    }

    private nonisolated static func scanLibrary(known: [String: Media], progress: @escaping @Sendable (Int, Int) -> Void) -> [Media] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] // newest months first
        let assets = PHAsset.fetchAssets(with: options)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMM"
        let newCount = max(assets.count - known.count, 1)
        var read = 0
        var result: [Media] = []
        result.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            if let saved = known[asset.localIdentifier], saved.modified == asset.modificationDate {
                result.append(saved)
                return
            }
            read += 1
            if read % 200 == 0 { progress(read, max(newCount, read)) }
            // A long first read survives being closed partway.
            if read % 5000 == 0 { saveCache(result) }
            let resources = PHAssetResource.assetResources(for: asset).filter { wanted.contains($0.type) }
            guard !resources.isEmpty else { return }
            let date = asset.creationDate ?? asset.modificationDate ?? Date()
            let sizes = resources.map(size(of:))
            let keys = zip(resources, sizes).map { resource, size in key(remoteName(resource, in: resources), size) }
            result.append(Media(
                id: asset.localIdentifier, modified: asset.modificationDate, created: asset.creationDate,
                month: formatter.string(from: date), filename: resources[0].originalFilename,
                isVideo: asset.mediaType == .video,
                isRaw: resources.contains { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true },
                keys: keys, sizes: sizes))
        }
        saveCache(result)
        return result
    }

    private static func groupByMonth(_ media: [Media]) -> [(month: String, items: [Media])] {
        Dictionary(grouping: media, by: \.month).map { (month: $0.key, items: $0.value) }.sorted { $0.month > $1.month }
    }

    private func updateCounts() {
        counts = media.reduce(into: [:]) { $0[state(of: $1), default: 0] += 1 }
    }

    /// PhotoKit has no public file size. Without it a file just gets sent, and the laptop spots the duplicate.
    nonisolated static func size(of resource: PHAssetResource) -> Int64? {
        guard resource.responds(to: Selector(("fileSize"))) else { return nil }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    private nonisolated static func key(_ name: String, _ size: Int64?) -> String? {
        size.map { "\(name.lowercased())|\($0)" }
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

    private func isKnown(_ key: String?) -> Bool {
        key.map { desktopKeys.contains($0) || laptopKeys.contains($0) } ?? false
    }

    func state(of item: Media) -> MediaState {
        if item.keys.allSatisfy({ $0.map(desktopKeys.contains) == true }) { return .desktop }
        if item.keys.allSatisfy(isKnown) { return .laptop }
        return .pending
    }

    // MARK: Laptop

    func refresh() async {
        guard let base = baseURL else { return }
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("manifest"))
            try Self.check(response)
            let latest = try JSONDecoder().decode(Manifest.self, from: data)
            manifest = latest
            desktopKeys = Set(latest.verified).union(latest.archive)
            laptopKeys = Set(latest.holding)
            updateCounts()
            if !running { lastError = nil }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return // the view went away, which says nothing about the laptop
        } catch {
            manifest = nil
            if !running { lastError = "Can't reach the laptop: \(error.localizedDescription)" }
        }
    }

    func loadHistory() async {
        guard let base = baseURL else { return }
        if let (data, response) = try? await session.data(from: base.appendingPathComponent("history")),
           (try? Self.check(response)) != nil,
           let rows = try? JSONDecoder().decode([HistoryRow].self, from: data) {
            history = rows
        }
    }

    /// Returns an error message, or nil when the laptop accepted the folder.
    func setDestination(_ path: String) async -> String? {
        guard let base = baseURL else { return "Add the laptop address first." }
        var components = URLComponents(url: base.appendingPathComponent("destination"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 400 { return "That isn't a full folder path. It should look like \\\\192.168.10.6\\d\\Photos or D:\\Photos." }
            try Self.check(response)
            await refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Automatic backup

    /// Why an automatic backup can't start right now; empty means it can.
    /// "Desktop reachable" stands in for "on home Wi-Fi": reading the network's name needs an Apple entitlement this signing doesn't get.
    var autoBlockers: [String] {
        var blockers: [String] = []
        if !onWiFi { blockers.append("Wi-Fi") }
        let battery = UIDevice.current.batteryState
        if battery != .charging && battery != .full { blockers.append("charging") }
        if manifest == nil { blockers.append("the laptop") }
        if manifest?.desktop_online != true { blockers.append("the desktop") }
        // Starting before the archive is known would re-send everything already there.
        if manifest?.archive_indexed != true { blockers.append("the desktop check to finish") }
        return blockers
    }

    /// Ids still to send. Failed items wait for a manual retry so one bad file can't loop forever.
    private var autoQueue: Set<String> {
        Set(media.filter { state(of: $0) == .pending && failed[$0.id] == nil }.map(\.id))
    }

    /// Called every 20 seconds while the app is open.
    func autoTick() {
        guard UserDefaults.standard.bool(forKey: "autoBackup"), !running, !scanning, !stoppedByUser, autoBlockers.isEmpty else { return }
        let ids = autoQueue
        if !ids.isEmpty { start(ids: ids) }
    }

    func resumeAuto() { stoppedByUser = false }

    /// iOS picks the moment, and only considers it while charging and online.
    nonisolated static func scheduleBackground() {
        guard UserDefaults.standard.bool(forKey: "autoBackup") else { return }
        let request = BGProcessingTaskRequest(identifier: backgroundTaskId)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackground(_ background: BGProcessingTask) async {
        Self.scheduleBackground()
        background.expirationHandler = { Task { @MainActor in Uploader.shared.task?.cancel() } }
        await loadLibrary()
        await refresh()
        if autoBlockers.isEmpty, !running {
            let ids = autoQueue
            if !ids.isEmpty {
                start(ids: ids)
                stoppedByUser = false
                await task?.value
            }
        }
        background.setTaskCompleted(success: true)
    }

    // MARK: Sending

    func start(ids: Set<String>) {
        guard !running, let base = baseURL else { return }
        running = true
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let limit = UserDefaults.standard.integer(forKey: "batchLimit")
        task = Task {
            do {
                await refresh()
                guard manifest != nil else { throw StopRun(message: lastError ?? "Can't reach the laptop.") }
                try await run(base: base, ids: ids, limit: limit)
                status = failed.isEmpty ? "Batch finished" : "Batch finished with \(failed.count) failed"
            } catch is CancellationError {
                status = "Stopped. Nothing is lost: send again to continue."
            } catch {
                status = "Paused. Send again to continue."
                lastError = error.localizedDescription
            }
            await refresh()
            selected.subtract(media.filter { state(of: $0) != .pending }.map(\.id))
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    func stop() {
        stoppedByUser = true // otherwise automatic backup would restart it 20 seconds later
        task?.cancel()
    }

    private func run(base: URL, ids: Set<String>, limit: Int) async throws {
        // Whole items only, so a limit never splits a Live Photo's two halves.
        var plan: [Media] = []
        var files = 0
        var total: Int64 = 0
        for item in media where ids.contains(item.id) {
            let missing = item.keys.indices.filter { !isKnown(item.keys[$0]) }
            if missing.isEmpty { continue }
            if files >= limit { break }
            plan.append(item)
            files += missing.count
            total += missing.compactMap { item.sizes[$0] }.reduce(0, +)
        }
        (batchDone, batchTotal, bytesDone, bytesTotal, batchStarted) = (0, files, 0, total, Date())

        for item in plan {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else { continue }
            let resources = PHAssetResource.assetResources(for: asset).filter { Self.wanted.contains($0.type) }
            failed[item.id] = nil
            for resource in resources {
                let name = Self.remoteName(resource, in: resources)
                if isKnown(Self.key(name, Self.size(of: resource))) { continue }
                try Task.checkCancellation()
                if UserDefaults.standard.bool(forKey: "wifiOnly"), !onWiFi {
                    throw StopRun(message: "Wi-Fi isn't connected, so sending stopped to save your mobile data. You can change this in Settings.")
                }
                status = "Sending \(resource.originalFilename)"
                do {
                    try await upload(resource, name: name, item: item, base: base)
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
    }

    private func upload(_ resource: PHAssetResource, name: String, item: Media, base: URL) async throws {
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

        let date = item.created ?? item.modified ?? Date()
        var components = URLComponents(url: base.appendingPathComponent("file"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
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
        bytesDone += Int64(size ?? 0)
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
