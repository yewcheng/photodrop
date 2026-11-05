import BackgroundTasks
import AVKit
import Photos
import SwiftUI

@main
struct PhotoDropApp: App {
    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Uploader.backgroundTaskId, using: nil) { task in
            Task { @MainActor in await Uploader.shared.handleBackground(task as! BGProcessingTask) }
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private func fileSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func monthTitle(_ month: String) -> String {
    let input = DateFormatter()
    input.locale = Locale(identifier: "en_US_POSIX")
    input.dateFormat = "yyyyMM"
    guard let date = input.date(from: month) else { return month }
    let output = DateFormatter()
    output.dateFormat = "MMMM yyyy"
    return output.string(from: date)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var uploader = Uploader.shared

    var body: some View {
        TabView {
            BackupTab(uploader: uploader)
                .tabItem { Label("Backup", systemImage: "arrow.up.circle") }
            LibraryTab(uploader: uploader)
                .tabItem { Label("Library", systemImage: "photo.on.rectangle") }
            HistoryTab(uploader: uploader)
                .tabItem { Label("History", systemImage: "clock") }
            SettingsTab(uploader: uploader)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // On the TabView, which never leaves the screen: inside a tab this restarts on every back-navigation.
        .task {
            await uploader.loadLibrary()
            // Keeps "waiting on laptop" moving to "on desktop" while the app is open.
            while !Task.isCancelled {
                await uploader.refresh()
                uploader.autoTick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .confirmationDialog("Delete transferred media from this phone?", isPresented: $uploader.showDeletePrompt, titleVisibility: .visible) {
            DeleteButtons(uploader: uploader)
            Button("Keep everything", role: .cancel) {}
        } message: {
            Text(DeleteButtons.warning(uploader))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { Uploader.scheduleBackground() }
            if phase == .active {
                uploader.resumeIfInterrupted()
                Task { await uploader.loadLibrary() }
            }
        }
    }
}

private struct BackupTab: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("autoBackup") private var autoBackup = false
    @ObservedObject var uploader: Uploader

    var body: some View {
        NavigationStack {
            Form {
                Section("Your library") {
                    HStack(alignment: .top) {
                        Stat(label: "On phone", value: uploader.media.count)
                        Stat(label: "On desktop", value: uploader.counts[.desktop] ?? 0)
                        Stat(label: "On laptop", value: uploader.counts[.laptop] ?? 0)
                        Stat(label: "To send", value: uploader.counts[.pending] ?? 0)
                    }
                }
                connection
                send
                if !uploader.deletablePhotos.isEmpty || !uploader.deletableVideos.isEmpty || uploader.deleteMessage != nil {
                    Section("Free up phone space") {
                        DeleteButtons(uploader: uploader)
                        InfoRow(title: "About deleting", value: uploader.deleteMessage ?? "", info: DeleteButtons.warning(uploader), isWarning: false)
                    }
                }
                if autoBackup {
                    let blockers = uploader.autoBlockers
                    Section {
                        InfoRow(
                            title: "Automatic backup",
                            value: blockers.isEmpty ? "Ready" : "Waiting",
                            info: blockers.isEmpty ? "Sends while the app is open, and when iOS allows it in the background." : "Waiting for: \(blockers.joined(separator: ", "))",
                            isWarning: false)
                    }
                }
            }
            .compactForm()
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var connection: some View {
        Section("Connection") {
            if let free = uploader.phoneFreeBytes {
                InfoRow(title: "Phone", value: "\(fileSize(free)) free")
            }
            if let manifest = uploader.manifest {
                InfoRow(title: "Laptop", value: "\(fileSize(manifest.laptop_free_bytes)) free")
                InfoRow(title: "Desktop", value: manifest.desktop_online ? "Reachable" : "Offline", info: desktopInfo(manifest))
                if manifest.desktop_online, uploader.moveTotal > 0 {
                    let done = uploader.moveTotal - manifest.holding.count
                    ProgressView(value: Double(done), total: Double(uploader.moveTotal)) {
                        Text("Copying to desktop: \(done) of \(uploader.moveTotal) files").font(.caption)
                    }
                }
            } else if serverURL.isEmpty {
                InfoRow(title: "Laptop", value: "Not set up", info: "Add the laptop address in Settings.")
            } else {
                InfoRow(title: "Laptop", value: "Not connected", info: uploader.lastError ?? "Check that the laptop is on and connected to Tailscale.")
            }
        }
    }

    private func desktopInfo(_ manifest: Manifest) -> String? {
        var notes: [String] = []
        if !manifest.desktop_online { notes.append("Files wait on the laptop until the desktop is back.") }
        if !manifest.archive_indexed { notes.append("The desktop hasn't been checked yet, so files already there may be sent again. The laptop won't duplicate them on the desktop.") }
        if let error = manifest.move_error { notes.append("Moving to the desktop: \(error)") }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }

    /// Measured from this batch's own speed, so it includes time spent fetching from iCloud.
    private var timeLeft: String {
        let elapsed = Date().timeIntervalSince(uploader.batchStarted)
        guard elapsed > 5, uploader.bytesDone > 0 else { return "Working it out…" }
        let seconds = Double(max(uploader.bytesTotal - uploader.bytesDone, 0)) / (Double(uploader.bytesDone) / elapsed)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return "About " + (formatter.string(from: seconds) ?? "")
    }

    private var send: some View {
        Section("Send") {
            if uploader.running {
                TransferProgress(uploader: uploader)
                LabeledContent("Time left", value: timeLeft)
                Button("Stop", role: .destructive) { uploader.stop() }
            } else {
                Button("Send everything not sent yet") {
                    let ids = uploader.media.filter { uploader.state(of: $0) == .pending }.map(\.id)
                    uploader.resumeAuto()
                    uploader.start(ids: Set(ids))
                }
                .disabled(uploader.manifest == nil || uploader.scanning)
                if !uploader.failed.isEmpty {
                    Button("Retry \(uploader.failed.count) failed") {
                        uploader.start(ids: Set(uploader.failed.keys))
                    }
                }
            }
            InfoRow(title: "Status", value: uploader.status, info: uploader.lastError)
            if uploader.running, let note = uploader.backgroundNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.subheadline.monospacedDigit().weight(.semibold)).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One line, with any longer explanation behind a tappable icon so warnings don't take up the screen.
private struct InfoRow: View {
    let title: String
    let value: String
    var info: String? = nil
    var isWarning = true
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            if let info {
                Button { showing = true } label: {
                    Image(systemName: isWarning ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundStyle(isWarning ? Color.orange : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("More about \(title)")
                .alert(title, isPresented: $showing) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(info)
                }
            }
        }
        .font(.subheadline)
    }
}

private extension View {
    @ViewBuilder func compactForm() -> some View {
        let tight = environment(\.defaultMinListRowHeight, 34)
        if #available(iOS 17.0, *) {
            tight.listSectionSpacing(.compact)
        } else {
            tight
        }
    }
}

/// Separate bars for count and size: one big video can move them very differently.
private struct TransferProgress: View {
    @ObservedObject var uploader: Uploader

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Files", value: "\(uploader.batchDone) of \(uploader.batchTotal)").font(.footnote)
            ProgressView(value: Double(min(uploader.batchDone, uploader.batchTotal)), total: Double(max(uploader.batchTotal, 1)))
            LabeledContent("Size", value: "\(fileSize(uploader.bytesDone)) of \(fileSize(uploader.bytesTotal))").font(.footnote)
            ProgressView(value: Double(min(uploader.bytesDone, uploader.bytesTotal)), total: Double(max(uploader.bytesTotal, 1)))
        }
    }
}

private struct DeleteButtons: View {
    @ObservedObject var uploader: Uploader

    static func warning(_ uploader: Uploader) -> String {
        "Only items confirmed by checksum on the desktop are offered. They go to Recently Deleted for 30 days. With iCloud Photos on, this also removes them from iCloud and your other devices."
    }

    var body: some View {
        let photos = uploader.deletablePhotos.count
        let videos = uploader.deletableVideos.count
        if photos > 0, videos > 0 {
            Button("Delete all \(photos + videos)", role: .destructive) { delete(photos: true, videos: true) }
        }
        if photos > 0 {
            Button("Delete \(videos > 0 ? "only " : "")\(photos) photos", role: .destructive) { delete(photos: true, videos: false) }
        }
        if videos > 0 {
            Button("Delete \(photos > 0 ? "only " : "")\(videos) videos", role: .destructive) { delete(photos: false, videos: true) }
        }
    }

    private func delete(photos: Bool, videos: Bool) {
        Task { await uploader.deleteFromPhone(photos: photos, videos: videos) }
    }
}

private struct LibraryTab: View {
    @ObservedObject var uploader: Uploader
    @State private var showAlbums = false
    @State private var albumMessage: String?

    private func isSynced(_ month: String) -> Bool {
        let stats = uploader.monthStats[month] ?? [:]
        return (stats[.pending] ?? 0) == 0 && (stats[.laptop] ?? 0) == 0 && !stats.isEmpty
    }

    private func rows(_ groups: [(month: String, items: [Media])]) -> some View {
        ForEach(groups, id: \.month) { group in
            NavigationLink {
                MonthView(uploader: uploader, month: group.month, items: group.items)
            } label: {
                MonthRow(uploader: uploader, month: group.month, count: group.items.count)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("View", selection: $showAlbums) {
                    Text("Months").tag(false)
                    Text("Albums").tag(true)
                }
                .pickerStyle(.segmented)
                if uploader.scanning {
                    HStack {
                        ProgressView()
                        Text(uploader.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if showAlbums {
                    Section {
                        ForEach(uploader.albums) { album in
                            Button {
                                let added = uploader.selectAlbum(album.id)
                                albumMessage = added == 0 ? "\(album.title): nothing left to send." : "\(album.title): selected \(added) not sent yet."
                            } label: {
                                LabeledContent(album.title, value: "\(album.count)")
                            }
                        }
                    } header: {
                        Text("Tap an album to select it")
                    } footer: {
                        if let albumMessage { Text(albumMessage) }
                    }
                } else {
                    let synced = uploader.months.filter { isSynced($0.month) }
                    let toSend = uploader.months.filter { !isSynced($0.month) }
                    if !toSend.isEmpty { Section("To send") { rows(toSend) } }
                    if !synced.isEmpty { Section("Fully on desktop") { rows(synced) } }
                }
            }
            .navigationTitle("Library")
            .task { await uploader.loadAlbums() }
        }
        // On the stack, not the list, so it also shows inside a month.
        .safeAreaInset(edge: .bottom) {
                if uploader.running {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(uploader.batchTotal == 0 ? uploader.status : "Sending")
                                .font(.footnote)
                            Spacer()
                            Button("Stop", role: .destructive) { uploader.stop() }
                        }
                        if uploader.batchTotal == 0 {
                            ProgressView()
                        } else {
                            TransferProgress(uploader: uploader)
                        }
                    }
                    .padding()
                    .background(.bar)
                } else if !uploader.selected.isEmpty {
                    HStack {
                        Button("Clear") { uploader.selected.removeAll() }
                        Spacer()
                        Button("Send \(uploader.selected.count) selected") {
                            uploader.start(ids: uploader.selected)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(uploader.manifest == nil || uploader.running)
                    }
                    .padding()
                    .background(.bar)
                }
        }
    }
}

private struct HistoryTab: View {
    @ObservedObject var uploader: Uploader

    var body: some View {
        NavigationStack {
            List {
                if !uploader.failed.isEmpty {
                    Section("Failed") {
                        ForEach(uploader.media.filter { uploader.failed[$0.id] != nil }) { item in
                            VStack(alignment: .leading) {
                                Text(item.filename)
                                Text(uploader.failed[item.id] ?? "").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Button("Retry all") { uploader.start(ids: Set(uploader.failed.keys)) }
                            .disabled(uploader.running)
                    }
                }
                Section("Latest transfers") {
                    if uploader.history.isEmpty { Text("Nothing transferred yet.").foregroundStyle(.secondary) }
                    ForEach(uploader.history) { row in
                        NavigationLink {
                            TransferredMediaView(row: row, url: uploader.mediaURL(key: row.key))
                        } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text(row.state == "verified" ? "Verified" : "On laptop")
                                    .font(.caption)
                                    .foregroundStyle(row.state == "verified" ? .green : .orange)
                            }
                            Text("\(fileSize(row.size)) · \(Date(timeIntervalSince1970: row.verified_at ?? row.received_at).formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            if let path = row.dest_path { Text(path).font(.caption2).foregroundStyle(.secondary) }
                            if let error = row.error { Text(error).font(.caption2).foregroundStyle(.red) }
                        }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .task { await uploader.loadHistory() }
            .refreshable { await uploader.loadHistory() }
        }
    }
}

/// Loads from the laptop or desktop, not the phone, so it still works after the phone's copy is deleted.
private struct TransferredMediaView: View {
    let row: HistoryRow
    let url: URL?

    private var isVideo: Bool {
        ["mov", "mp4", "m4v"].contains((row.name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if let url, isVideo {
                VideoPlayer(player: AVPlayer(url: url))
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: Text("Not available. If it's on the desktop, the laptop must be able to reach it.").padding()
                    default: ProgressView()
                    }
                }
            } else {
                Text("Add the laptop address in Settings.")
            }
        }
        .navigationTitle(row.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsTab: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("batchLimit") private var batchLimit = 500
    @AppStorage("wifiOnly") private var wifiOnly = true
    @AppStorage("hideDeletePrompt") private var hideDeletePrompt = false
    @AppStorage("autoBackup") private var autoBackup = false
    @AppStorage("coolMode") private var coolMode = false
    @ObservedObject var uploader: Uploader
    @State private var destination = ""
    @State private var destinationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://laptop.tailnet.ts.net:5443", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await uploader.refresh() } }
                } header: {
                    Text("Laptop address")
                } footer: {
                    Text(uploader.manifest == nil ? "Not connected" : "Connected")
                }
                Section {
                    TextField("D:\\Photos", text: $destination)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save folder") {
                        Task {
                            let error = await uploader.setDestination(destination)
                            destinationMessage = error ?? "Saved. The laptop will re-check what's in this folder."
                        }
                    }
                    .disabled(uploader.manifest == nil || destination.isEmpty || destination == uploader.manifest?.destination)
                } header: {
                    Text("Desktop folder")
                } footer: {
                    Text(destinationMessage ?? "Year and month folders are created inside this one, reusing any that exist.")
                }
                Section("Sending") {
                    Picker("Most files per batch", selection: $batchLimit) {
                        Text("100").tag(100)
                        Text("500").tag(500)
                        Text("1,000").tag(1000)
                        Text("5,000").tag(5000)
                        Text("No limit").tag(Int.max)
                    }
                    Toggle("Only send on Wi-Fi", isOn: $wifiOnly)
                    Toggle("Cool mode (one file at a time, slower)", isOn: $coolMode)
                    // The Free up phone space buttons on Backup stay either way.
                    Toggle("Offer to delete after sending", isOn: Binding(get: { !hideDeletePrompt }, set: { hideDeletePrompt = !$0 }))
                }
                Section {
                    Toggle("Automatic backup", isOn: $autoBackup)
                        .onChange(of: autoBackup) { on in
                            if on {
                                uploader.resumeAuto()
                                Uploader.scheduleBackground()
                            }
                        }
                } footer: {
                    Text("Sends when the phone is charging, on Wi-Fi, and the desktop is reachable. It starts within seconds while the app is open. In the background, iOS decides when it runs, which may be overnight or not at all.")
                }
            }
            .navigationTitle("Settings")
            .onReceive(uploader.$manifest) { manifest in
                if destination.isEmpty, let saved = manifest?.destination { destination = saved }
            }
        }
    }
}

private struct MonthRow: View {
    @ObservedObject var uploader: Uploader
    let month: String
    let count: Int

    var body: some View {
        let stats = uploader.monthStats[month] ?? [:]
        VStack(alignment: .leading, spacing: 2) {
            Text(monthTitle(month))
            Text("\(count) items · \(stats[.desktop] ?? 0) on desktop · \(stats[.laptop] ?? 0) waiting · \(stats[.pending] ?? 0) to send")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos", raw = "RAW"
    var id: String { rawValue }

    func includes(_ item: Media) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !item.isVideo
        case .videos: return item.isVideo
        case .raw: return item.isRaw
        }
    }
}

private struct MonthView: View {
    @ObservedObject var uploader: Uploader
    let month: String
    let items: [Media]
    @State private var filter = MediaFilter.all

    var body: some View {
        let shown = items.filter(filter.includes)
        ScrollView {
            Picker("Show", selection: $filter) {
                ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                ForEach(shown) { item in
                    Thumbnail(id: item.id, side: 300)
                        .overlay(alignment: .topTrailing) { badge(for: item) }
                        .accessibilityLabel(item.filename)
                        .accessibilityAddTraits(uploader.selected.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .onTapGesture { toggle(item) }
                        .contextMenu {
                            Text(item.filename)
                            Text(item.created?.formatted() ?? "")
                            Text(fileSize(item.size))
                        } preview: {
                            Thumbnail(id: item.id, side: 1200).frame(width: 320, height: 320)
                        }
                }
            }
        }
        .navigationTitle(monthTitle(month))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu("Select") {
                Button("Everything not sent yet") {
                    uploader.selected.formUnion(shown.filter { uploader.state(of: $0) == .pending }.map(\.id))
                }
                Button("All") { uploader.selected.formUnion(shown.map(\.id)) }
                Button("None") { uploader.selected.subtract(shown.map(\.id)) }
            }
        }
    }

    private func toggle(_ item: Media) {
        if uploader.selected.remove(item.id) == nil { uploader.selected.insert(item.id) }
    }

    @ViewBuilder private func badge(for item: Media) -> some View {
        Group {
            if uploader.selected.contains(item.id) {
                Image(systemName: "circle.inset.filled").foregroundStyle(.blue)
            } else if uploader.failed[item.id] != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            } else {
                switch uploader.state(of: item) {
                case .desktop: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .laptop: Image(systemName: "clock.fill").foregroundStyle(.orange)
                case .pending: EmptyView()
                }
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Circle())
        .padding(4)
    }
}

private struct Thumbnail: View {
    let id: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: id) {
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
                let options = PHImageRequestOptions()
                options.deliveryMode = .opportunistic
                options.isNetworkAccessAllowed = true
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options
                ) { result, _ in
                    if let result { image = result }
                }
            }
    }
}
