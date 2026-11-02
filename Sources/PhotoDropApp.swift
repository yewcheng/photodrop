import Photos
import SwiftUI

@main
struct PhotoDropApp: App {
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
    @AppStorage("serverURL") private var serverURL = ""
    @AppStorage("batchLimit") private var batchLimit = 500
    @StateObject private var uploader = Uploader()

    private var months: [(month: String, items: [Media])] {
        Dictionary(grouping: uploader.media, by: \.month)
            .map { (month: $0.key, items: $0.value) }
            .sorted { $0.month > $1.month }
    }

    var body: some View {
        NavigationStack {
            Form {
                overview
                sending
                Section("Months") {
                    ForEach(months, id: \.month) { group in
                        NavigationLink {
                            MonthView(uploader: uploader, month: group.month, items: group.items)
                        } label: {
                            MonthRow(uploader: uploader, month: group.month, items: group.items)
                        }
                    }
                }
                Section("Laptop address") {
                    TextField("https://laptop.tailnet.ts.net:5443", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await uploader.refresh(server: serverURL) } }
                }
            }
            .navigationTitle("PhotoDrop")
            .task {
                await uploader.loadLibrary()
                // Keeps "waiting on laptop" moving to "on desktop" while the screen is open.
                while !Task.isCancelled {
                    await uploader.refresh(server: serverURL)
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
        }
    }

    private var overview: some View {
        let counts = Dictionary(grouping: uploader.media) { uploader.state(of: $0) }.mapValues(\.count)
        return Section("Overview") {
            LabeledContent("On this phone", value: "\(uploader.media.count)")
            LabeledContent("On desktop", value: "\(counts[.desktop] ?? 0)")
            LabeledContent("Waiting on laptop", value: "\(counts[.laptop] ?? 0)")
            LabeledContent("Not sent yet", value: "\(counts[.pending] ?? 0)")
            if let manifest = uploader.manifest {
                LabeledContent("Laptop", value: "Connected, \(fileSize(manifest.laptop_free_bytes)) free")
                LabeledContent("Desktop", value: manifest.desktop_online ? "Reachable" : "Offline, files wait on laptop")
                if !manifest.archive_indexed {
                    Text("The desktop hasn't been checked yet, so files already there may be sent again. The laptop won't duplicate them on the desktop.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error = manifest.move_error {
                    Text("Moving to the desktop: \(error)").font(.footnote).foregroundStyle(.orange)
                }
            } else {
                LabeledContent("Laptop", value: "Not connected")
            }
        }
    }

    private var sending: some View {
        Section("Send") {
            Picker("Most files per batch", selection: $batchLimit) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1,000").tag(1000)
                Text("No limit").tag(Int.max)
            }
            if uploader.running {
                Button("Stop", role: .destructive) { uploader.stop() }
                ProgressView(value: Double(uploader.batchDone), total: Double(max(uploader.batchTotal, 1)))
                LabeledContent("Files", value: "\(uploader.batchDone) of \(uploader.batchTotal)")
                LabeledContent("Data sent", value: fileSize(uploader.bytes))
            } else {
                Button("Send \(uploader.selected.count) selected") {
                    uploader.start(server: serverURL, ids: uploader.selected, limit: batchLimit)
                }
                .disabled(uploader.selected.isEmpty || uploader.manifest == nil)
                Button("Send everything not sent yet") {
                    let ids = uploader.media.filter { uploader.state(of: $0) == .pending }.map(\.id)
                    uploader.start(server: serverURL, ids: Set(ids), limit: batchLimit)
                }
                .disabled(uploader.manifest == nil || uploader.scanning)
                if !uploader.failed.isEmpty {
                    Button("Retry \(uploader.failed.count) failed") {
                        uploader.start(server: serverURL, ids: Set(uploader.failed.keys), limit: batchLimit)
                    }
                }
            }
            Text(uploader.status).font(.footnote)
            if let error = uploader.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
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
                    Thumbnail(asset: item.asset, side: 300)
                        .overlay(alignment: .topTrailing) { badge(for: item) }
                        .accessibilityLabel(item.filename)
                        .accessibilityAddTraits(uploader.selected.contains(item.id) ? [.isButton, .isSelected] : .isButton)
                        .onTapGesture { toggle(item) }
                        .contextMenu {
                            Text(item.filename)
                            Text(item.asset.creationDate?.formatted() ?? "")
                            Text(fileSize(item.size))
                        } preview: {
                            Thumbnail(asset: item.asset, side: 1200).frame(width: 320, height: 320)
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
    let asset: PHAsset
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
            .task(id: asset.localIdentifier) {
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
