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

struct AlbumInfo: Identifiable {
    let id: String
    let title: String
    let count: Int
}

@MainActor
final class Uploader: ObservableObject {
    static let shared = Uploader()
    // Built from the installed ID, which SideStore changes; each form is listed in project.yml.
    nonisolated static let backgroundTaskId = (Bundle.main.bundleIdentifier ?? "com.photodrop.backup") + ".process"
    static let sendTaskId = (Bundle.main.bundleIdentifier ?? "com.photodrop.backup") + ".send"
    /// iOS 26's BGContinuedProcessingTask, kept untyped because stored properties can't be availability-gated.
    private var continuedTask: AnyObject?

    @Published var media: [Media] = [] { didSet { months = Self.groupByMonth(media) } }
    @Published private(set) var months: [(month: String, items: [Media])] = []
    @Published private(set) var counts: [MediaState: Int] = [:]
    @Published private(set) var monthStats: [String: [MediaState: Int]] = [:]
    @Published private(set) var deletablePhotos: [String] = []
    @Published private(set) var deletableVideos: [String] = []
    @Published private(set) var phoneFreeBytes: Int64?
    @Published private(set) var albums: [AlbumInfo] = []
    @Published var showDeletePrompt = false
    @Published var deleteMessage: String?
    @Published var manifest: Manifest?
    @Published var history: [HistoryRow] = []
    @Published var selected: Set<String> = []
    @Published var failed: [String: String] = [:]
    @Published var running = false
    @Published var scanning = false
    @Published var status = "Ready"
    @Published var batchDone = 0 { didSet { reportContinued() } }
    @Published var batchTotal = 0
    @Published var bytesDone: Int64 = 0 { didSet { reportContinued() } }
    @Published var bytesTotal: Int64 = 0
    @Published var batchStarted = Date()
    @Published var lastError: String?
    @Published private(set) var onWiFi = false

    private var desktopKeys = Set<String>()
    private var laptopKeys = Set<String>()
    /// Most files seen waiting on the laptop since it was last empty, for the laptop-to-desktop bar.
    @Published private(set) var moveTotal = 0
    private var verifiedKeys = Set<String>()
    private var countGeneration = 0
    private var task: Task<Void, Never>?
    private var stoppedByUser = false
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi) // tells Wi-Fi apart even with Tailscale's VPN on
    private var sessionCache: (token: String?, session: URLSession)?
    /// Rebuilt when pairing changes the token, which every request carries.
    private var session: URLSession {
        let token = Pairing.token
        if let sessionCache, sessionCache.token == token { return sessionCache.session }
        sessionCache?.session.finishTasksAndInvalidate()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true // ride out Wi-Fi handoffs while walking around
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 6 * 3600
        if let token { config.httpAdditionalHeaders = ["X-PhotoDrop-Token": token] }
        let session = URLSession(configuration: config, delegate: CertPin(), delegateQueue: nil)
        sessionCache = (token, session)
        return session
    }

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
            } partial: { items in
                // Newest first, so the latest months appear long before the read finishes.
                Task { @MainActor in
                    let shelf = Uploader.shared
                    if shelf.scanning, shelf.media.count < items.count {
                        shelf.media = items
                        shelf.updateCounts()
                    }
                }
            }
        }.value
        updateCounts()
        if !running { status = "Ready" }
    }

    private nonisolated static func scanLibrary(known: [String: Media], progress: @escaping @Sendable (Int, Int) -> Void, partial: @escaping @Sendable ([Media]) -> Void) -> [Media] {
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
            if known.isEmpty, read == 200 || read % 2000 == 0 { partial(result) }
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
        // Off the main thread: at 97,000 items this would otherwise stall scrolling and taps.
        countGeneration += 1
        let generation = countGeneration
        let (items, desktop, verified, laptop) = (media, desktopKeys, verifiedKeys, laptopKeys)
        phoneFreeBytes = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([MediaState: Int], [String: [MediaState: Int]], [String], [String]) in
                var counts: [MediaState: Int] = [:]
                var months: [String: [MediaState: Int]] = [:]
                var photos: [String] = []
                var videos: [String] = []
                for item in items {
                    let state = Self.state(keys: item.keys, desktop: desktop, laptop: laptop)
                    counts[state, default: 0] += 1
                    months[item.month, default: [:]][state, default: 0] += 1
                    // Only a checksum match counts here. A name and size match with the old archive isn't proof enough to delete.
                    if item.keys.allSatisfy({ $0.map(verified.contains) == true }) {
                        if item.isVideo { videos.append(item.id) } else { photos.append(item.id) }
                    }
                }
                return (counts, months, photos, videos)
            }.value
            guard generation == countGeneration else { return }
            (counts, monthStats, deletablePhotos, deletableVideos) = result
            offerDeleteIfNew()
        }
    }

    private func offerDeleteIfNew() {
        let total = deletablePhotos.count + deletableVideos.count
        let offered = UserDefaults.standard.integer(forKey: "deleteOfferedCount")
        if total < offered { UserDefaults.standard.set(total, forKey: "deleteOfferedCount") }
        // Wait until the laptop has finished copying, so the offer covers the whole batch.
        guard total > offered, !UserDefaults.standard.bool(forKey: "hideDeletePrompt"), !running, laptopKeys.isEmpty, UIApplication.shared.applicationState == .active else { return }
        UserDefaults.standard.set(total, forKey: "deleteOfferedCount")
        showDeletePrompt = true
    }

    // MARK: Deleting from the phone

    func deleteFromPhone(photos: Bool, videos: Bool) async {
        await deleteFromPhone(ids: Set((photos ? deletablePhotos : []) + (videos ? deletableVideos : [])))
    }

    /// Checksum-confirmed on the desktop, so safe to offer for deletion.
    var backedUp: Set<String> { Set(deletablePhotos).union(deletableVideos) }

    func deleteFromPhone(ids: Set<String>) async {
        guard let base = baseURL else { return }
        let items = media.filter { ids.contains($0.id) }
        do {
            // Ask again right now: the database says it was verified, this says it's still there.
            var request = URLRequest(url: base.appendingPathComponent("still-there"))
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(items.flatMap { $0.keys.compactMap { $0 } })
            let (data, response) = try await session.data(for: request)
            try Self.check(response)
            let present = Set(try JSONDecoder().decode([String].self, from: data))
            let safe = items.filter { $0.keys.allSatisfy { $0.map(present.contains) == true } }.map(\.id)
            guard !safe.isEmpty else {
                deleteMessage = "Nothing deleted: the desktop must be reachable so its copies can be confirmed."
                return
            }
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: safe, options: nil)
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
            let kept = items.count - safe.count
            deleteMessage = "Moved \(safe.count) to Recently Deleted." + (kept > 0 ? " Kept \(kept) not confirmed on the desktop." : "")
            await loadLibrary()
        } catch let error as NSError where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.userCancelled.rawValue {
            deleteMessage = "Nothing deleted."
        } catch {
            deleteMessage = "Nothing deleted: \(error.localizedDescription)"
        }
    }

    // MARK: Albums

    func loadAlbums() async {
        albums = await Task.detached(priority: .userInitiated) { () -> [AlbumInfo] in
            var result: [AlbumInfo] = []
            for type in [PHAssetCollectionType.album, .smartAlbum] {
                PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { album, _, _ in
                    let count = PHAsset.fetchAssets(in: album, options: nil).count
                    if count > 0 { result.append(AlbumInfo(id: album.localIdentifier, title: album.localizedTitle ?? "Album", count: count)) }
                }
            }
            return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }.value
    }

    /// Adds the album's unsent items to the selection and says how many that was.
    func selectAlbum(_ id: String) -> Int {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { return 0 }
        var ids = Set<String>()
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        let unsent = media.filter { ids.contains($0.id) && state(of: $0) == .pending }.map(\.id)
        selected.formUnion(unsent)
        return unsent.count
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
        Self.state(keys: item.keys, desktop: desktopKeys, laptop: laptopKeys)
    }

    private nonisolated static func state(keys: [String?], desktop: Set<String>, laptop: Set<String>) -> MediaState {
        if keys.allSatisfy({ $0.map(desktop.contains) == true }) { return .desktop }
        if keys.allSatisfy({ $0.map { desktop.contains($0) || laptop.contains($0) } == true }) { return .laptop }
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
            moveTotal = latest.holding.isEmpty ? 0 : max(moveTotal, latest.holding.count)
            verifiedKeys = Set(latest.verified)
            updateCounts()
            if let notes = Diag.takePrevious() {
                var request = URLRequest(url: base.appendingPathComponent("diag"))
                request.httpMethod = "POST"
                _ = try? await session.upload(for: request, from: notes)
            }
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

    func mediaURL(key: String) -> URL? {
        guard let base = baseURL else { return nil }
        guard var components = URLComponents(url: base.appendingPathComponent("media"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    func loadHistory() async {
        guard let base = baseURL else { return }
        if let (data, response) = try? await session.data(from: base.appendingPathComponent("history")),
           (try? Self.check(response)) != nil,
           let rows = try? JSONDecoder().decode([HistoryRow].self, from: data) {
            history = rows
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

    /// Set when iOS suspended a send because the app left the screen; it carries on when the app returns.
    private var interruptedIds: Set<String>?

    func resumeIfInterrupted() {
        guard let ids = interruptedIds else { return }
        interruptedIds = nil
        start(ids: ids, resume: true)
    }

    func start(ids: Set<String>, resume: Bool = false) {
        guard !running, let base = baseURL else { return }
        running = true
        Diag.note("start \(ids.count) items resume=\(resume) cool=\(UserDefaults.standard.bool(forKey: "coolMode"))")
        lastError = nil
        status = "Getting ready…"
        if !resume { (batchDone, batchTotal, bytesDone, bytesTotal, batchStarted) = (0, 0, 0, 0, Date()) }
        // Before iOS 26 a locked screen stops sending; after, the screen can sleep and save battery.
        if #unavailable(iOS 26.0) { UIApplication.shared.isIdleTimerDisabled = true }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Asks iOS to keep sending after the app is left, with its own progress on the Lock Screen and Dynamic Island.
            // Registered per send: iOS throws an uncatchable exception if the exact ID has no handler.
            let id = "\(Self.sendTaskId).\(UUID().uuidString)"
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                Diag.note("continued task launched: \(type(of: task))")
                Task { @MainActor in Uploader.shared.attachContinued(task as! BGContinuedProcessingTask) }
            }
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Sending to laptop", subtitle: "Getting ready…")
            request.strategy = .fail
            continuedIds = ids
            backgroundNote = "Waiting for iOS to accept background sending…"
            Diag.note("register \(registered)")
            if !registered {
                backgroundNote = "iOS wouldn't register background sending, so keep PhotoDrop open (app ID \(Bundle.main.bundleIdentifier ?? "?"))."
            } else { do { try BGTaskScheduler.shared.submit(request); Diag.note("submitted") } catch {
                Diag.note("submit failed \(error)")
                backgroundNote = "iOS refused background sending, so keep PhotoDrop open: \(error.localizedDescription) (\((error as NSError).code), app ID \(Bundle.main.bundleIdentifier ?? "?"))"
            } }
        }
        #endif
        // Fallback before iOS 26: iOS allows about 30 seconds after leaving the app, then suspends it; this asks for that time.
        var grace = UIBackgroundTaskIdentifier.invalid
        grace = UIApplication.shared.beginBackgroundTask {
            Diag.note("grace expired")
            Task { @MainActor in
                // With iOS 26's background send running, this short grace ending must not stop it.
                if Uploader.shared.continuedTask == nil {
                    Uploader.shared.interruptedIds = ids
                    Uploader.shared.task?.cancel()
                }
                UIApplication.shared.endBackgroundTask(grace)
            }
        }
        let limit = UserDefaults.standard.integer(forKey: "batchLimit")
        task = Task {
            do {
                // The 20-second refresh keeps this current; waiting on another here delays the first file.
                if manifest == nil { await refresh() }
                guard manifest != nil else { throw StopRun(message: lastError ?? "Can't reach the laptop.") }
                try await run(base: base, ids: ids, limit: limit, resume: resume)
                status = failed.isEmpty ? "Batch finished" : "Batch finished with \(failed.count) failed"
            } catch is CancellationError {
                Diag.note("cancelled")
                status = interruptedIds == nil ? "Stopped. Nothing is lost: send again to continue." : "Paused while PhotoDrop was in the background. It continues when you come back."
            } catch {
                Diag.note("run error \(error)")
                if UIApplication.shared.applicationState != .active {
                    interruptedIds = ids
                    status = "Paused while PhotoDrop was in the background. It continues when you come back."
                } else {
                    status = "Paused. Send again to continue."
                    lastError = error.localizedDescription
                }
            }
            updateCounts()
            selected.subtract(media.filter { state(of: $0) != .pending }.map(\.id))
            running = false
            UIApplication.shared.isIdleTimerDisabled = false
            finishContinued(success: interruptedIds == nil)
            await refresh()
            UIApplication.shared.endBackgroundTask(grace)
        }
    }

    private var continuedIds: Set<String> = []
    /// Whether iOS took the background send, shown in the app because a refusal is otherwise invisible.
    @Published private(set) var backgroundNote: String?

    private var lastContinuedTitle = Date.distantPast

    private func reportContinued() {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask, batchTotal > 0 else { return }
        // iOS ends a task whose progress stops moving, so count bytes: they move during a long video, files don't.
        task.progress.totalUnitCount = max(bytesTotal, 1)
        task.progress.completedUnitCount = min(bytesDone, bytesTotal)
        // Byte updates arrive many times a second; the title only needs one.
        guard Date().timeIntervalSince(lastContinuedTitle) > 1 else { return }
        lastContinuedTitle = Date()
        task.updateTitle("Sending to laptop", subtitle: "\(batchDone) of \(batchTotal) files · \(ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file))")
        #endif
    }

    private func finishContinued(success: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        #endif
        continuedTask = nil
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    func attachContinued(_ task: BGContinuedProcessingTask) {
        guard running else { task.setTaskCompleted(success: true); return }
        continuedTask = task
        Diag.note("continued task attached")
        backgroundNote = "Sending continues in other apps. Progress shows on the Lock Screen and Dynamic Island."
        let ids = continuedIds
        // The system's Stop button, or iOS needing the resources back: pause, and carry on when the app is opened.
        task.expirationHandler = {
            Diag.note("continued task expired")
            Task { @MainActor in
                Uploader.shared.interruptedIds = ids
                Uploader.shared.task?.cancel()
            }
        }
        reportContinued()
    }
    #endif

    func stop() {
        stoppedByUser = true // otherwise automatic backup would restart it 20 seconds later
        task?.cancel()
    }

    private func run(base: URL, ids: Set<String>, limit: Int, resume: Bool) async throws {
        // A resumed send finishes the original batch instead of starting a new full-size one on top.
        let limit = resume ? max(0, batchTotal - batchDone) : limit
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
        // A resumed send keeps its counts and clock, so the bars carry on instead of starting again.
        let (doneBefore, bytesBefore) = resume ? (batchDone, bytesDone) : (0, 0)
        (batchDone, batchTotal, bytesDone, bytesTotal) = (doneBefore, doneBefore + files, bytesBefore, bytesBefore + total)
        if !resume { batchStarted = Date() }
        (bytesFinished, bytesInFlight) = (bytesDone, [:])

        // Photos are looked up only as they're about to be sent: thousands up front froze the app until iOS closed it.
        var items = plan.makeIterator()
        var queued: [(item: Media, resource: PHAssetResource, name: String)] = []
        func nextJob() -> (item: Media, resource: PHAssetResource, name: String)? {
            while queued.isEmpty, let item = items.next() {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else { continue }
                let resources = PHAssetResource.assetResources(for: asset).filter { Self.wanted.contains($0.type) }
                failed[item.id] = nil
                for resource in resources {
                    let name = Self.remoteName(resource, in: resources)
                    if !isKnown(Self.key(name, Self.size(of: resource))) { queued.append((item, resource, name)) }
                }
            }
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        // Several files at once, so one being prepared or checksummed never leaves the link (and iOS's progress) idle.
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Cool mode: one at a time, for less heat and battery at the cost of speed.
            for _ in 0..<(UserDefaults.standard.bool(forKey: "coolMode") ? 1 : Self.parallelSends) {
                guard let job = nextJob() else { break }
                group.addTask { try await self.sendOne(job.resource, name: job.name, item: job.item, base: base) }
            }
            while try await group.next() != nil {
                guard let job = nextJob() else { continue }
                group.addTask { try await self.sendOne(job.resource, name: job.name, item: job.item, base: base) }
            }
        }
    }

    private static let parallelSends = 3

    private func sendOne(_ resource: PHAssetResource, name: String, item: Media, base: URL) async throws {
        try Task.checkCancellation()
        if UserDefaults.standard.bool(forKey: "wifiOnly"), !onWiFi {
            throw StopRun(message: "Wi-Fi isn't connected, so sending stopped to save your mobile data. You can change this in Settings.")
        }
        status = "Preparing \(resource.originalFilename)"
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
            Diag.note("file failed \(resource.originalFilename): \(error)")
            failed[item.id] = error.localizedDescription
            lastError = "\(resource.originalFilename): \(error.localizedDescription)"
        }
        batchDone += 1
    }

    /// Bytes of finished files, plus bytes so far of each file still sending; bytesDone is their sum.
    private var bytesFinished: Int64 = 0
    private var bytesInFlight: [UUID: Int64] = [:]

    private func setSent(_ token: UUID, _ sent: Int64?) {
        guard bytesInFlight[token] != nil else { return } // a late update after the file finished
        bytesInFlight[token] = sent
        // Each change redraws the whole list; unthrottled, that kept the CPU busy enough for iOS to flag it.
        guard sent == nil || Date().timeIntervalSince(lastBytesPublish) > 0.25 else { return }
        lastBytesPublish = Date()
        bytesDone = bytesFinished + bytesInFlight.values.reduce(0, +)
    }
    private var lastBytesPublish = Date.distantPast

    private func upload(_ resource: PHAssetResource, name: String, item: Media, base: URL) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }

        // writeData hands back the stored bytes untouched, and fetches from iCloud when needed.
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let label = resource.originalFilename
        Diag.note("read \(label) \(Self.size(of: resource) ?? -1)")
        options.progressHandler = { fraction in
            Task { @MainActor in Uploader.shared.status = "Downloading \(label) from iCloud: \(Int(fraction * 100))%" }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }

        Diag.note("read done \(label)")
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
        status = "Sending \(label)"
        // Counts bytes as they go, so a large video moves the bar instead of sitting at zero.
        let token = UUID()
        bytesInFlight[token] = 0
        defer { setSent(token, nil) }
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: SentBytes { sent in
            Task { @MainActor in Uploader.shared.setSent(token, sent) }
        })
        Diag.note("sent \(label)")
        try Self.check(response)
        let reply = try JSONDecoder().decode(PutReply.self, from: data)
        if reply.state == "holding" { laptopKeys.insert(reply.key) } else { desktopKeys.insert(reply.key) }
        let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        bytesFinished += Int64(size ?? 0)
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
            // Each chunk is released as it goes; without the pool a 7.6 GB video piled up in memory until iOS killed the app.
            while try autoreleasepool(invoking: {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }) {}
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

private final class SentBytes: NSObject, URLSessionTaskDelegate {
    let onSent: @Sendable (Int64) -> Void
    init(_ onSent: @escaping @Sendable (Int64) -> Void) { self.onSent = onSent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(totalBytesSent)
    }
}
