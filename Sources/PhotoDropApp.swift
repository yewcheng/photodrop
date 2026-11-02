import BackgroundTasks
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
        .onChange(of: scenePhase) { phase in
            if phase == .background { Uploader.scheduleBackground() }
            if phase == .active { Task { await uploader.loadLibrary() } }
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
                    LabeledContent("On this phone", value: "\(uploader.media.count)")
                    LabeledContent("On desktop", value: "\(uploader.counts[.desktop] ?? 0)")
                    LabeledContent("Waiting on laptop", value: "\(uploader.counts[.laptop] ?? 0)")
                    LabeledContent("Not sent yet", value: "\(uploader.counts[.pending] ?? 0)")
                }
                connection
                send
                if autoBackup {
                    Section("Automatic backup") {
                        let blockers = uploader.autoBlockers
                        Text(blockers.isEmpty ? "Ready: sends while the app is open, and when iOS allows it in the background." : "Waiting for: \(blockers.joined(separator: ", "))")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Backup")
        }
    }

    @ViewBuilder private var connection: some View {
        Section("Connection") {
            if let manifest = uploader.manifest {
                LabeledContent("Laptop", value: "\(fileSize(manifest.laptop_free_bytes)) free")
                LabeledContent("Desktop", value: manifest.desktop_online ? "Reachable" : "Offline")
                if !manifest.desktop_online {
                    Text("Files wait on the laptop until the desktop is back.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !manifest.archive_indexed {
                    Text("The desktop hasn't been checked yet, so files already there may be sent again. The laptop won't duplicate them on the desktop.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error = manifest.move_error {
                    Text("Moving to the desktop: \(error)").font(.footnote).foregroundStyle(.orange)
                }
            } else if serverURL.isEmpty {
                Text("Add the laptop address in Settings.")
            } else {
                LabeledContent("Laptop", value: "Not connected")
            }
        }
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
                ProgressView(value: min(Double(uploader.bytesDone), Double(max(uploader.bytesTotal, 1))), total: Double(max(uploader.bytesTotal, 1)))
                LabeledContent("Files", value: "\(uploader.batchDone) of \(uploader.batchTotal)")
                LabeledContent("Data", value: "\(fileSize(uploader.bytesDone)) of \(fileSize(uploader.bytesTotal))")
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
            Text(uploader.status).font(.footnote).foregroundStyle(.secondary)
            if let error = uploader.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }
}

private struct LibraryTab: View {
    @ObservedObject var uploader: Uploader

    var body: some View {
        NavigationStack {
            List(uploader.months, id: \.month) { group in
                NavigationLink {
                    MonthView(uploader: uploader, month: group.month, items: group.items)
                } label: {
                    MonthRow(uploader: uploader, month: group.month, items: group.items)
                }
            }
            .navigationTitle("Library")
            .overlay {
                if uploader.scanning && uploader.media.isEmpty { ProgressView("Reading your photo library…") }
            }
            // Outside the month pushes too, so the selection can be sent from any month.
            .safeAreaInset(edge: .bottom) {
                if !uploader.selected.isEmpty {
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
            .navigationTitle("History")
            .task { await uploader.loadHistory() }
            .refreshable { await uploader.loadHistory() }
        }
    }
}

private struct SettingsTab: View {
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("batchLimit") private var batchLimit = 500
    @AppStorage("wifiOnly") private var wifiOnly = true
    @AppStorage("autoBackup") private var autoBackup = false
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
                        Text("No limit").tag(Int.max)
                    }
                    Toggle("Only send on Wi-Fi", isOn: $wifiOnly)
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
    let items: [Media]

    var body: some View {
        let counts = Dictionary(grouping: items) { uploader.state(of: $0) }.mapValues(\.count)
        VStack(alignment: .leading, spacing: 2) {
            Text(monthTitle(month))
            Text("\(items.count) items · \(counts[.desktop] ?? 0) on desktop · \(counts[.laptop] ?? 0) waiting · \(counts[.pending] ?? 0) to send")
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
