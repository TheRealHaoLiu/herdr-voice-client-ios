// The herdr-voice server, called the way its phone page and the Mac app call it.
import Foundation
import Network
import Security

struct VoiceError: LocalizedError { let message: String; var errorDescription: String? { message } }

// What pairing leaves on the phone. The access key lives in the Keychain; the server address and
// its public certificate authority are not secret and live in the app's settings.
enum Store {
    private static let d = UserDefaults.standard
    static var server: String? { get { d.string(forKey: "server") } set { d.set(newValue, forKey: "server") } }
    static var caPEM: String? { get { d.string(forKey: "ca") } set { d.set(newValue, forKey: "ca") } }
    static let clientId: String = { // tells the server which device you last talked through
        if let c = d.string(forKey: "clientId") { return c }
        let c = "ios-" + UUID().uuidString.prefix(8).lowercased(); d.set(c, forKey: "clientId"); return c
    }()

    private static let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "herdr-voice", kSecAttrAccount as String: "access-key"]
    static var key: String? {
        get {
            var q = item; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(item as CFDictionary)
            guard let newValue else { return }
            var q = item; q[kSecValueData as String] = Data(newValue.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
    static var paired: Bool { server != nil && caPEM != nil && key != nil }
    static func forget() { key = nil; server = nil; caPEM = nil }
}

// Trust only the server's own certificate authority (the file a phone installs for the web page).
final class PinnedTrust: NSObject, URLSessionDelegate {
    let pem: () -> String?
    init(pem: @escaping () -> String?) { self.pem = pem }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let b64 = pem()?.components(separatedBy: "-----").dropFirst(2).first?
                  .components(separatedBy: .whitespacesAndNewlines).joined(),
              let der = Data(base64Encoded: b64),
              let anchor = SecCertificateCreateWithData(nil, der as CFData) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
}

final class API {
    static let unreachable = "Can't reach the voice server."
    private let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust { Store.caPEM }, delegateQueue: nil)

    func call(_ path: String, method: String = "GET", body: Data? = nil, type: String? = nil, timeout: TimeInterval = 240) async throws -> [String: Any] {
        guard let server = Store.server, let key = Store.key, let url = URL(string: server + path) else {
            throw VoiceError(message: "This phone is not paired with a voice server.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method; req.httpBody = body; req.timeoutInterval = timeout
        req.setValue(key, forHTTPHeaderField: "x-voice-key")
        req.setValue(Store.clientId, forHTTPHeaderField: "x-voice-client")
        if let type { req.setValue(type, forHTTPHeaderField: "content-type") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw VoiceError(message: API.unreachable + " (\(why(error)))") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if code == 401 { throw VoiceError(message: "The server no longer accepts this phone's key. Pair again.") }
        if code == 403, obj == nil { throw VoiceError(message: "The server refused this phone's address.") }
        guard let obj else { throw VoiceError(message: "The server sent something unreadable.") }
        return obj
    }

    static func query(_ t: String) -> String {
        var ok = CharacterSet.urlQueryAllowed; ok.remove(charactersIn: "&+=?/")
        return "?t=" + (t.addingPercentEncoding(withAllowedCharacters: ok) ?? t)
    }

    /// Trade the one-time code in a pairing link for the access key.
    /// The link is https://<address>:<port>/#pair=<code>. The server's certificate authority comes from
    /// its plain-HTTP side door on the next port and is trusted from then on, as the web page does.
    static func pair(link: String) async throws {
        guard let u = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme == "https", let host = u.host, !host.isEmpty,
              let code = u.fragment?.components(separatedBy: "&").first(where: { $0.hasPrefix("pair=") })?.dropFirst(5), !code.isEmpty
        else { throw VoiceError(message: "That is not a herdr-voice pairing code.") }
        let port = u.port ?? 443
        let literal = host.contains(":") ? "[\(host)]" : host // an IPv6 address goes in brackets
        let server = "https://\(literal):\(port)"
        let pem = try await certificate(host: host, port: port + 1)

        let session = URLSession(configuration: .ephemeral, delegate: PinnedTrust { pem }, delegateQueue: nil)
        var req = URLRequest(url: URL(string: server + "/api/pair")!)
        req.httpMethod = "POST"; req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": String(code)])
        let data: Data
        do { (data, _) = try await session.data(for: req) }
        catch { throw VoiceError(message: "The server's certificate was not accepted, or it stopped answering. (\(why(error)))") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceError(message: "The server refused this phone's address.") }
        guard let key = obj["key"] as? String, !key.isEmpty else {
            throw VoiceError(message: (obj["error"] as? String) ?? "That code has expired or was used. Show a new one.")
        }
        Store.caPEM = pem; Store.server = server; Store.key = key
    }

    /// The server's public certificate authority, from its plain-HTTP side door. Fetched over a plain
    /// socket: iOS's rules for web requests refuse plain HTTP, and this one file is public and is
    /// checked by the pairing call that follows. Waits up to 20 seconds, which leaves time to answer
    /// iOS's "find devices on your local network" question the first time.
    static func certificate(host: String, port: Int) async throws -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw VoiceError(message: "That is not a herdr-voice pairing code.") }
        let queue = DispatchQueue(label: "herdr-voice.pair")
        let reply: Data = try await withCheckedThrowingContinuation { done in
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            var finished = false, got = Data(), waitingOn = "no answer"
            func finish(_ result: Result<Data, Error>) { if !finished { finished = true; conn.cancel(); done.resume(with: result) } }
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data { got.append(data) }
                    if complete || error != nil { finish(.success(got)) } else { read() }
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET /ca.crt HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(request.utf8), completion: .contentProcessed { e in if let e { finish(.failure(e)) } else { read() } })
                case .failed(let e): finish(.failure(VoiceError(message: API.unreachable + " (\(e.localizedDescription))")))
                case .waiting(let e): waitingOn = e.localizedDescription // not final: it goes on once the network or the permission allows
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) {
                finish(.failure(VoiceError(message: API.unreachable + " (\(waitingOn)) Is the phone on the same network, and is Local Network allowed for Herdr Voice in Settings?")))
            }
        }
        let text = String(decoding: reply, as: UTF8.self)
        if text.hasPrefix("HTTP/1.1 403") { throw VoiceError(message: "The server refused this phone's address.") }
        guard let from = text.range(of: "-----BEGIN CERTIFICATE-----"), let to = text.range(of: "-----END CERTIFICATE-----", range: from.upperBound..<text.endIndex) else {
            throw VoiceError(message: "Could not fetch the server's certificate.")
        }
        return String(text[from.lowerBound..<to.upperBound]) + "\n"
    }
}

/// A short reason for a failed network call, for the screen.
func why(_ error: Error) -> String {
    let e = error as NSError
    return e.domain == NSURLErrorDomain ? "\(e.localizedDescription) [\(e.code)]" : e.localizedDescription
}
