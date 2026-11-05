import CryptoKit
import Security
import SwiftUI
import UIKit
import VisionKit

/// Pairing with the laptop by QR code or typed code, over its home-network HTTPS listener (no Tailscale).
/// The QR code carries the laptop certificate's fingerprint, so only that laptop is trusted; the token it
/// hands back lives in the Keychain and is sent on every request.
enum Pairing {
    private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PhotoDrop",
        kSecAttrAccount as String: "laptop-token",
    ]
    private static var cached: String??

    /// Readable after the first unlock, so sending can carry on with the screen locked.
    static var token: String? {
        get {
            if let cached { return cached }
            var query = keychainQuery
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            let value = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
                ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
            cached = .some(value)
            return value
        }
        set {
            SecItemDelete(keychainQuery as CFDictionary)
            if let newValue {
                var item = keychainQuery
                item[kSecValueData as String] = Data(newValue.utf8)
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(item as CFDictionary, nil)
            }
            cached = .some(newValue)
        }
    }

    /// The paired laptop's certificate fingerprint, and the host it's trusted for.
    static var pinnedCert: String? { UserDefaults.standard.string(forKey: "pinnedCert") }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// `fingerprint` comes from the QR code; a typed code has none, so the first certificate seen is trusted.
    static func pair(address: String, code: String, fingerprint: String?) async throws {
        guard let base = URL(string: address.trimmingCharacters(in: .whitespaces)), base.scheme == "https", base.host != nil else {
            throw Failure(errorDescription: "The address should look like https://192.168.1.20:8865")
        }
        let pin = CertPin(fixed: fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: pin, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: base.appendingPathComponent("pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code.filter(\.isNumber), "name": UIDevice.current.name])
        request.timeoutInterval = 15
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw Failure(errorDescription: pin.mismatch
                ? "This isn't the laptop in the QR code. Pairing stopped for safety."
                : "Can't reach the laptop. Check both are on the same Wi-Fi. (\(error.localizedDescription))")
        }
        struct Reply: Decodable { let token: String?; let detail: String? }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let token = reply?.token, let seen = pin.seen else {
            throw Failure(errorDescription: reply?.detail ?? "The laptop refused the code.")
        }
        Self.token = token
        UserDefaults.standard.set(seen, forKey: "pinnedCert")
        UserDefaults.standard.set(base.host, forKey: "pinnedHost")
        UserDefaults.standard.set(base.absoluteString, forKey: "serverURL")
    }

    static func unpair() {
        token = nil
        UserDefaults.standard.removeObject(forKey: "pinnedCert")
        UserDefaults.standard.removeObject(forKey: "pinnedHost")
    }

    /// photodrop://pair?u=<address>&c=<code>&f=<fingerprint>
    static func parse(_ link: String) -> (address: String, code: String, fingerprint: String)? {
        guard let parts = URLComponents(string: link), parts.scheme == "photodrop", parts.host == "pair" else { return nil }
        let value = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        guard let u = value("u"), let c = value("c"), let f = value("f") else { return nil }
        return (u, c, f)
    }
}

/// Trusts the laptop's self-signed certificate only if its SHA-256 matches the paired one.
/// Other hosts (such as a Tailscale address with a real certificate) get the normal checks.
final class CertPin: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let fixed: String?
    private let pairing: Bool
    private(set) var seen: String?
    private(set) var mismatch = false

    /// For pairing: `fixed` from the QR code, or nil to trust the first certificate (typed code).
    init(fixed: String?) { self.fixed = fixed?.lowercased(); pairing = true }
    /// For everyday sending: checks against the stored pin.
    override init() { fixed = nil; pairing = false }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let expected: String?
        if pairing {
            expected = fixed
        } else {
            guard challenge.protectionSpace.host == UserDefaults.standard.string(forKey: "pinnedHost"),
                  let pin = Pairing.pinnedCert else { return (.performDefaultHandling, nil) }
            expected = pin
        }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        if let expected, fingerprint != expected {
            mismatch = true
            return (.cancelAuthenticationChallenge, nil)
        }
        seen = fingerprint
        return (.useCredential, URLCredential(trust: trust))
    }
}

struct PairSheet: View {
    var scanned: String? = nil
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if scanned == nil, DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    Section {
                        QRScanner { link in Task { await pair(link: link) } }
                            .frame(height: 280)
                            .listRowInsets(EdgeInsets())
                    } header: {
                        Text("Scan the code on the laptop")
                    } footer: {
                        Text("On the laptop, open http://127.0.0.1:8860/pair")
                    }
                }
                Section("Or type it in") {
                    TextField("https://192.168.1.20:8865", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                    Button("Pair") {
                        Task { await run { try await Pairing.pair(address: address, code: code, fingerprint: nil) } }
                    }
                    .disabled(busy || address.isEmpty || code.filter(\.isNumber).count != 6)
                }
                if busy || message != nil {
                    Section { Text(busy ? "Pairing…" : message ?? "") }
                }
            }
            .navigationTitle("Pair with laptop")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { if let scanned { await pair(link: scanned) } }
        }
    }

    private func pair(link: String) async {
        guard !busy else { return }
        guard let found = Pairing.parse(link) else { message = "That isn't a PhotoDrop pairing code."; return }
        await run { try await Pairing.pair(address: found.address, code: found.code, fingerprint: found.fingerprint) }
    }

    private func run(_ attempt: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await attempt()
            onDone()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                if let value = code.payloadStringValue { onFound(value); return }
            }
        }
    }
}
