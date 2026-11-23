import CryptoKit
import Foundation

/// This watch's pairing with a Mac through the relay.
struct RelayPairing: Codable {
    let url: String
    let watchId: String
    let watchSecret: String
    let macPublicKey: String   // base64url, 32 bytes
    let macName: String
    let privateKey: String     // this watch's X25519 key, base64
    var confirmed: Bool
}

/// Reaches the Mac through the relay: no tunnel or domain needed. Requests and answers are
/// encrypted end to end with a key only this watch and the Mac have (see docs/ARCHITECTURE.md).
enum Relay {
    private static let info = Data("claude-watch v1".utf8)

    /// The relay this build uses unless Settings names another (RELAY_HOST in Base.xcconfig).
    static var defaultURL: String {
        let host = (Bundle.main.object(forInfoDictionaryKey: "RelayHost") as? String) ?? ""
        return host.isEmpty || host.hasPrefix("$(") ? "" : "https://\(host)"
    }

    static var pairing: RelayPairing? {
        get {
            guard let data = Bridge.shared.data(forKey: "relayPairing") else { return nil }
            return try? JSONDecoder().decode(RelayPairing.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Bridge.shared.set(data, forKey: "relayPairing")
            } else {
                Bridge.shared.removeObject(forKey: "relayPairing")
            }
        }
    }

    static var isPaired: Bool { pairing?.confirmed == true }

    // MARK: Pairing

    private struct Joined: Codable { let watchId: String; let watchSecret: String; let macPk: String; let macName: String }
    private struct Status: Codable { let confirmed: Bool; let online: Bool }
    private struct Failure: Codable { let error: String }

    /// Uses the code shown on the Mac. Returns the check number to compare with the Mac's.
    static func join(code: String, relayURL: String) async throws -> String {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let pk = key.publicKey.rawRepresentation.base64URL
        let joined: Joined = try await send("POST", relayURL + "/v1/join", body: ["code": code, "pk": pk, "name": watchName], auth: nil)
        pairing = RelayPairing(url: relayURL, watchId: joined.watchId, watchSecret: joined.watchSecret,
                               macPublicKey: joined.macPk, macName: joined.macName,
                               privateKey: key.rawRepresentation.base64EncodedString(), confirmed: false)
        return try checkNumber(macPublicKey: joined.macPk, watchPublicKey: pk)
    }

    /// Whether the Mac confirmed the pairing yet, and whether it is connected right now.
    static func status() async throws -> (confirmed: Bool, online: Bool) {
        guard var current = pairing else { throw BridgeError(message: "Not paired") }
        let status: Status = try await send("GET", current.url + "/v1/watch/status", body: nil, auth: auth(current))
        if status.confirmed && !current.confirmed {
            current.confirmed = true
            pairing = current
        }
        return (status.confirmed, status.online)
    }

    static func unpair() async {
        if let current = pairing {
            let _: [String: Bool]? = try? await send("DELETE", current.url + "/v1/watch", body: nil, auth: auth(current))
        }
        pairing = nil
    }

    /// Six digits from both public keys. The Mac shows the same ones when nothing is in between.
    static func checkNumber(macPublicKey: String, watchPublicKey: String) throws -> String {
        guard let mac = Data(base64URL: macPublicKey), let watch = Data(base64URL: watchPublicKey) else {
            throw BridgeError(message: "Bad key from the relay")
        }
        let digest = Array(SHA256.hash(data: Data("claude-watch check".utf8) + mac + watch))
        let n = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", n)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }

    // MARK: Talking to the Mac

    /// One API request to the bridge on the Mac, sealed for it alone.
    static func call(_ method: String, _ path: String, body: [String: Any]?) async throws -> (status: Int, body: Data) {
        guard let current = pairing, current.confirmed else { throw BridgeError(message: "Pair with your Mac in Settings.") }
        let key = try sharedKey(current)
        var request: [String: Any] = ["method": method, "path": path]
        if let body { request["body"] = body }
        let sealed = try ChaChaPoly.seal(JSONSerialization.data(withJSONObject: request), using: key,
                                         authenticating: Data(current.watchId.utf8)).combined
        struct Box: Codable { let box: String? }
        let reply: Box = try await send("POST", current.url + "/v1/watch/rpc", body: ["box": sealed.base64EncodedString()], auth: auth(current))
        guard let box = reply.box, let data = Data(base64Encoded: box) else {
            throw BridgeError(message: "Your Mac doesn't recognize this watch. Pair again in Settings.")
        }
        let opened = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key, authenticating: Data(current.watchId.utf8))
        guard let answer = try JSONSerialization.jsonObject(with: opened) as? [String: Any] else {
            throw BridgeError(message: "Unreadable answer from your Mac")
        }
        let status = answer["status"] as? Int ?? 500
        let bodyData = try JSONSerialization.data(withJSONObject: answer["body"] ?? [:])
        return (status, bodyData)
    }

    /// Where the relay should send this watch's notifications.
    static func registerDevice(_ token: String, sandbox: Bool, kind: String) async throws {
        guard let current = pairing, current.confirmed else { return }
        let _: [String: Bool] = try await send("POST", current.url + "/v1/watch/devices",
                                               body: ["token": token, "sandbox": sandbox, "kind": kind], auth: auth(current))
    }

    // MARK: Plumbing

    private static func auth(_ p: RelayPairing) -> String { "\(p.watchId):\(p.watchSecret)" }

    private static var watchName: String {
        #if os(watchOS)
        return "Apple Watch"
        #else
        return "Device"
        #endif
    }

    private static func sharedKey(_ p: RelayPairing) throws -> SymmetricKey {
        guard let privateData = Data(base64Encoded: p.privateKey), let macData = Data(base64URL: p.macPublicKey) else {
            throw BridgeError(message: "Pairing data is damaged. Pair again in Settings.")
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateData)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: macData))
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: macData + privateKey.publicKey.rawRepresentation,
                                              sharedInfo: info, outputByteCount: 32)
    }

    private static func send<T: Decodable>(_ method: String, _ urlString: String, body: [String: Any]?, auth: String?) async throws -> T {
        guard let url = URL(string: urlString) else { throw BridgeError(message: "No relay address. Check Settings.") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let error as URLError where error.code != .cancelled {
            throw BridgeError(message: error.code == .notConnectedToInternet ? "Your watch is offline." : "Can't reach the relay.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            switch (status, message) {
            case (503, _): throw BridgeError(message: "Your Mac isn't connected. It may be asleep, or the bridge isn't running.")
            case (504, _): throw BridgeError(message: "Your Mac didn't answer in time.")
            case (401, _) where auth != nil: throw BridgeError(message: "This watch is no longer paired. Pair again in Settings.")
            default: throw BridgeError(message: message ?? "Relay returned \(status)")
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension Data {
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
