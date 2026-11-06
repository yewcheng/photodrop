import Foundation

/// Step-by-step notes for a run that ends with no crash report: written as they happen,
/// sent to the laptop on the next launch (phone-diag.log there).
enum Diag {
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("diag.log")
    private static let previousURL = url.deletingLastPathComponent().appendingPathComponent("diag-previous.log")
    private static let lock = NSLock()

    /// Call once at launch: keeps the last run's notes for sending and catches Objective-C exceptions.
    static func start() {
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: url, to: previousURL)
        NSSetUncaughtExceptionHandler { exception in
            Diag.note("EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "")\n" + exception.callStackSymbols.prefix(25).joined(separator: "\n"))
        }
        note("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
    }

    static func note(_ text: String) {
        let line = Data("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(text)\n".utf8)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// The previous run's notes, once; nil if there were none.
    static func takePrevious() -> Data? {
        defer { try? FileManager.default.removeItem(at: previousURL) }
        return try? Data(contentsOf: previousURL)
    }
}
