import SwiftUI

@main
struct PhotoDropApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @AppStorage("serverURL") private var serverURL = ""
    @StateObject private var uploader = Uploader()

    var body: some View {
        NavigationStack {
            Form {
                Section("Laptop address") {
                    TextField("https://laptop.tailnet.ts.net:5443", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    if uploader.running {
                        Button("Stop", role: .destructive) { uploader.stop() }
                    } else {
                        Button("Start backup") { uploader.start(server: serverURL) }
                            .disabled(URL(string: serverURL)?.host == nil)
                    }
                }
                Section("Progress") {
                    Text(uploader.status)
                    if uploader.total > 0 {
                        ProgressView(value: Double(uploader.checked), total: Double(uploader.total))
                        LabeledContent("Items checked", value: "\(uploader.checked) of \(uploader.total)")
                    }
                    LabeledContent("Files uploaded", value: "\(uploader.uploaded)")
                    LabeledContent("Data sent", value: ByteCountFormatter.string(fromByteCount: uploader.bytes, countStyle: .file))
                    LabeledContent("Failed", value: "\(uploader.failed)")
                    if let error = uploader.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("PhotoDrop")
        }
    }
}
