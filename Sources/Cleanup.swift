import Photos
import SwiftUI
import Vision

/// Suggests clutter to delete: similar shots, old screenshots, very short videos and unpicked burst frames.
/// Everything runs on the phone, and only items already checksum-confirmed on the desktop are ever suggested.
@MainActor
final class Cleanup: ObservableObject {
    static let shared = Cleanup()

    /// Each group is ordered keeper first.
    @Published private(set) var similar: [[String]] = []
    @Published private(set) var screenshots: [String] = []
    @Published private(set) var shortVideos: [String] = []
    @Published private(set) var burstExtras: [String] = []
    @Published private(set) var status: String?
    @Published private(set) var running = false
    @Published private(set) var scanned = false
    private(set) var sizes: [String: Int64] = [:]

    func scan(_ uploader: Uploader) {
        guard !running else { return }
        running = true
        let backedUp = uploader.backedUp
        sizes = Dictionary(uploader.media.map { ($0.id, $0.size) }, uniquingKeysWith: { first, _ in first })
        let sizeSnapshot = sizes
        Task {
            status = "Sorting \(backedUp.count) backed-up items…"
            let found = await Task.detached(priority: .utility) { Self.categorise(backedUp) }.value
            (screenshots, shortVideos, burstExtras, similar) = (found.screenshots, found.shortVideos, found.bursts, [])
            scanned = true
            // Comparing pictures is the slow part, so it only runs on photos taken within a minute of each other, and only while charging.
            for (index, run) in found.runs.enumerated() {
                let battery = UIDevice.current.batteryState
                guard battery == .charging || battery == .full else {
                    status = "Paused after \(index) of \(found.runs.count) bursts of photos. Plug in the phone and tap Look again."
                    running = false
                    return
                }
                status = "Comparing photos: \(index) of \(found.runs.count)"
                let groups = await Task.detached(priority: .utility) { Self.group(run, sizes: sizeSnapshot) }.value
                similar += groups
            }
            status = nil
            running = false
        }
    }

    /// Drops suggestions for items no longer on the phone.
    func prune(onPhone: Set<String>) {
        similar = similar.map { $0.filter(onPhone.contains) }.filter { $0.count > 1 }
        screenshots = screenshots.filter(onPhone.contains)
        shortVideos = shortVideos.filter(onPhone.contains)
        burstExtras = burstExtras.filter(onPhone.contains)
    }

    private struct Found: Sendable {
        var screenshots: [String] = []
        var shortVideos: [String] = []
        var bursts: [String] = []
        var runs: [[String]] = []
    }

    private nonisolated static func categorise(_ backedUp: Set<String>) -> Found {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        var found = Found()
        var run: [String] = []
        var lastDate: Date?
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            guard backedUp.contains(id) else { return }
            if asset.mediaType == .video {
                if asset.duration < 2 { found.shortVideos.append(id) }
                return
            }
            guard asset.mediaType == .image else { return }
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                if (asset.creationDate ?? .distantFuture) < monthAgo { found.screenshots.append(id) }
                return
            }
            if asset.burstIdentifier != nil, asset.burstSelectionTypes.isEmpty {
                found.bursts.append(id)
                return
            }
            if let lastDate, let date = asset.creationDate, date.timeIntervalSince(lastDate) <= 60 {
                run.append(id)
            } else {
                if run.count > 1 { found.runs.append(run) }
                run = [id]
            }
            lastDate = asset.creationDate
        }
        if run.count > 1 { found.runs.append(run) }
        return found
    }

    /// Splits photos taken close together into groups that look alike, keeper first.
    private nonisolated static func group(_ run: [String], sizes: [String: Int64]) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var previous: VNFeaturePrintObservation?
        for id in run {
            let print = featurePrint(id)
            var distance: Float = .infinity
            if let print, let previous { try? previous.computeDistance(&distance, to: print) }
            // shortcut: one fixed threshold, tuned by eye; make it a setting if it groups too much or too little.
            if distance < 0.45 {
                current.append(id)
            } else {
                if current.count > 1 { groups.append(current) }
                current = [id]
            }
            previous = print
        }
        if current.count > 1 { groups.append(current) }
        let favourites = Set(groups.flatMap { $0 }.filter {
            PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject?.isFavorite == true
        })
        // Keep a favourite, else the biggest file: the sharpest shot compresses least.
        return groups.map { group in
            group.sorted { a, b in
                if favourites.contains(a) != favourites.contains(b) { return favourites.contains(a) }
                return (sizes[a] ?? 0) > (sizes[b] ?? 0)
            }
        }
    }

    private nonisolated static func featurePrint(_ id: String) -> VNFeaturePrintObservation? {
        autoreleasepool {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false // the phone's own preview is enough to compare
            var image: CGImage?
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit, options: options) { result, _ in
                image = result?.cgImage
            }
            guard let image else { return nil }
            let request = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        }
    }
}

struct CleanupTab: View {
    @ObservedObject var uploader: Uploader
    @ObservedObject private var cleanup = Cleanup.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(cleanup.running ? "Looking…" : cleanup.scanned ? "Look again" : "Look for clutter") { cleanup.scan(uploader) }
                        .disabled(cleanup.running || uploader.backedUp.isEmpty)
                    if let status = cleanup.status { Text(status).foregroundStyle(.secondary) }
                } footer: {
                    Text("Only photos and videos already confirmed on the desktop are suggested, and you choose what goes. Comparing similar photos runs while the phone is charging.")
                }
                if cleanup.scanned {
                    Section("Suggestions") {
                        link("Similar photos", "Keeps the favourite or sharpest of each set", groups: cleanup.similar, grouped: true)
                        link("Screenshots over a month old", nil, groups: [cleanup.screenshots], grouped: false)
                        link("Videos under 2 seconds", "Usually accidental", groups: [cleanup.shortVideos], grouped: false)
                        link("Unpicked burst photos", "The burst's chosen photo stays", groups: [cleanup.burstExtras], grouped: false)
                    }
                }
                if let message = uploader.deleteMessage {
                    Section { Text(message) }
                }
            }
            .navigationTitle("Clean up")
        }
    }

    private func link(_ title: String, _ detail: String?, groups: [[String]], grouped: Bool) -> some View {
        let offered = grouped ? groups.flatMap { $0.dropFirst() } : groups.flatMap { $0 }
        let bytes = offered.compactMap { cleanup.sizes[$0] }.reduce(0, +)
        return NavigationLink {
            PickView(uploader: uploader, title: title, groups: groups, grouped: grouped)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(offered.count) items · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\(detail.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(offered.isEmpty)
    }
}

private struct PickView: View {
    @ObservedObject var uploader: Uploader
    let title: String
    let groups: [[String]]
    /// Grouped: the first of each group is kept and the rest preselected. Otherwise everything is preselected.
    let grouped: Bool
    @State private var chosen: Set<String> = []
    @State private var confirming = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups.indices, id: \.self) { index in
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 2)], spacing: 2) {
                        ForEach(groups[index], id: \.self) { id in
                            Thumbnail(id: id, side: 300)
                                .overlay(alignment: .topTrailing) { badge(id, keeper: grouped && id == groups[index].first) }
                                .opacity(chosen.contains(id) ? 0.6 : 1)
                                .onTapGesture { if chosen.remove(id) == nil { chosen.insert(id) } }
                                .accessibilityAddTraits(chosen.contains(id) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    if grouped { Divider() }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { chosen = Set(grouped ? groups.flatMap { $0.dropFirst() } : groups.flatMap { $0 }) }
        .toolbar {
            Button("Delete \(chosen.count)", role: .destructive) { confirming = true }
                .disabled(chosen.isEmpty)
        }
        .confirmationDialog("Delete \(chosen.count) items from this phone?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete \(chosen.count)", role: .destructive) {
                let ids = chosen
                Task {
                    await uploader.deleteFromPhone(ids: ids)
                    Cleanup.shared.prune(onPhone: Set(uploader.media.map(\.id)))
                    chosen.subtract(ids)
                }
            }
        } message: {
            Text("Tap a picture to keep or delete it. Only items confirmed by checksum on the desktop are shown. They go to Recently Deleted for 30 days. With iCloud Photos on, this also removes them from iCloud.")
        }
    }

    @ViewBuilder private func badge(_ id: String, keeper: Bool) -> some View {
        Group {
            if chosen.contains(id) {
                Image(systemName: "trash.circle.fill").foregroundStyle(.red)
            } else if keeper {
                Text("Keep").font(.caption2.bold()).padding(.horizontal, 4)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(4)
    }
}
