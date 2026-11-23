import Foundation

struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let project: String
    let updatedAt: Double
    let state: String
    let preview: String
    let watchCopy: Bool?
    let needsYou: Bool?
}

struct Turn: Codable, Hashable {
    let role: String
    let text: String
}

struct PendingMessage: Codable, Hashable {
    let prompt: String
    let startedAt: Double
}

/// A question Claude is waiting on, with the answers offered.
struct Choices: Codable, Hashable {
    let question: String
    let options: [String]
}

struct SessionDetail: Codable {
    let id: String
    let title: String
    let project: String
    let state: String
    let watchCopy: Bool?
    let canStop: Bool?
    let turns: [Turn]
    let pending: PendingMessage?
    let error: String?
    let choices: Choices?
    /// Set while the session shows a dialog on the Mac, such as a permission prompt.
    let waitingOnMac: String?
}

/// How much of one usage limit is spent (0...1) and when it resets.
struct UsageWindow: Codable, Hashable {
    let used: Double
    let resetsAt: Double
    var resetDate: Date { Date(timeIntervalSince1970: resetsAt) }
}

/// The 5-hour session limit only shows up once Claude starts reporting it.
struct UsageInfo: Codable, Hashable {
    let session: UsageWindow?
    let week: UsageWindow?
    /// The limit you'd hit first: the session window when it is reported, else the week.
    var headline: UsageWindow? { session ?? week }
}

struct WaitingSession: Codable, Hashable {
    let id: String
    let title: String
    let question: String
}

/// Everything the watch face shows, from one request.
struct BridgeStatus: Codable, Hashable {
    let needsYou: Int
    let working: Int
    let idle: Int
    let top: WaitingSession?
    let usage: UsageInfo?

    static let sample = BridgeStatus(
        needsYou: 1, working: 2, idle: 3,
        top: WaitingSession(id: "", title: "Apple Watch app", question: "Merge the two branches here?"),
        usage: UsageInfo(session: UsageWindow(used: 0.62, resetsAt: Date.now.timeIntervalSince1970 + 6000), week: UsageWindow(used: 0.38, resetsAt: Date.now.timeIntervalSince1970 + 300_000))
    )
}

/// Links the watch face and notifications use to open the app at the right place.
enum AppLink {
    static func session(_ id: String) -> URL { URL(string: "claudewatch://session/\(id)")! }
    static let home = URL(string: "claudewatch://sessions")!

    static func sessionID(from url: URL) -> String? {
        guard url.scheme == "claudewatch", url.host == "session" else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty || id == "/" ? nil : id
    }
}

extension Error {
    /// A request dropped because the view that made it went away or restarted, not a real failure.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the bridge server running on the Mac.
enum Bridge {
    private struct SessionList: Codable { let sessions: [SessionSummary] }
    private struct Started: Codable { let id: String; let title: String? }
    private struct Failure: Codable { let error: String }
    private struct Rotated: Codable { let token: String }

    /// Settings shared by the app and the watch face, so both use the same address and token.
    static let shared = UserDefaults(suiteName: appGroup) ?? .standard

    /// group.<BUNDLE_PREFIX>, worked out from this target's bundle id (see Base.xcconfig).
    private static var appGroup: String {
        var id = Bundle.main.bundleIdentifier ?? ""
        for suffix in [".widgets", ".watchkitapp"] where id.hasSuffix(suffix) {
            id.removeLast(suffix.count)
        }
        return "group." + id
    }

    // A direct address and token, for running without the relay (Settings → Direct connection).
    static var baseURL: String { setting("baseURL") ?? "" }
    static var token: String { setting("token") ?? "" }
    static var usesDirect: Bool { !Relay.isPaired && !baseURL.isEmpty && !token.isEmpty }
    static var isConfigured: Bool { Demo.isOn || Relay.isPaired || usesDirect }

    private static func setting(_ key: String) -> String? {
        let value = (shared.string(forKey: key) ?? UserDefaults.standard.string(forKey: key))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func sessions() async throws -> [SessionSummary] {
        let list: SessionList = try await request("GET", "/sessions")
        return list.sessions
    }

    static func session(_ id: String) async throws -> SessionDetail {
        try await request("GET", "/sessions/\(id)")
    }

    /// Returns the session that will answer: a watch copy when the original is open on the Mac.
    static func send(_ text: String, to id: String) async throws -> String {
        let started: Started = try await request("POST", "/sessions/\(id)/message", text: text)
        return started.id
    }

    /// Starts a new session, or, for "Tell <session> …", messages that session instead.
    static func startSession(_ text: String) async throws -> (id: String, title: String) {
        let started: Started = try await request("POST", "/sessions", text: text)
        return (started.id, started.title ?? text)
    }

    static func stop(_ id: String) async throws {
        let _: Started = try await request("POST", "/sessions/\(id)/stop")
    }

    /// The watch face's numbers. Also remembered, so a short gap shows the last known state.
    static func status() async throws -> BridgeStatus {
        let status: BridgeStatus = try await request("GET", "/status")
        if let data = try? JSONEncoder().encode(status) {
            shared.set(data, forKey: "lastStatus")
            shared.set(Date.now.timeIntervalSince1970, forKey: "lastStatusAt")
        }
        return status
    }

    /// The last status that arrived, and when, for when the Mac can't be reached right now.
    static var lastStatus: (status: BridgeStatus, at: Date)? {
        guard let data = shared.data(forKey: "lastStatus"),
              let status = try? JSONDecoder().decode(BridgeStatus.self, from: data) else { return nil }
        return (status, Date(timeIntervalSince1970: shared.double(forKey: "lastStatusAt")))
    }

    private struct Registered: Codable { let ok: Bool; let push: Bool }

    /// Tells the bridge where to send pushes: "app" for alerts, "widgets" for watch face reloads.
    static func registerDevice(_ token: String, sandbox: Bool, kind: String = "app") async throws {
        // Remembered, so they can be sent again after pairing.
        shared.set(token, forKey: "pushToken.\(kind)")
        if Demo.isOn { return }
        if Relay.isPaired {
            try await Relay.registerDevice(token, sandbox: sandbox, kind: kind)
        } else if usesDirect {
            let _: Registered = try await request("POST", "/devices", body: ["token": token, "sandbox": sandbox, "kind": kind])
        }
    }

    /// Sends the push tokens this watch already has to wherever alerts now come from.
    static func reregisterDevices() async {
        for kind in ["app", "widgets"] {
            if let token = shared.string(forKey: "pushToken.\(kind)") {
                try? await registerDevice(token, sandbox: pushSandbox, kind: kind)
            }
        }
    }

    /// Replaces the pairing token. The old one, including the one built into the app, stops working.
    static func rotateToken() async throws {
        let rotated: Rotated = try await request("POST", "/token/rotate", body: nil)
        shared.set(rotated.token, forKey: "token")
    }

    /// Whether pushes from Apple come from its sandbox (builds installed from Xcode) or production.
    static var pushSandbox: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func request<T: Decodable>(_ method: String, _ path: String, text: String? = nil) async throws -> T {
        try await request(method, path, body: text.map { ["text": $0] })
    }

    private static func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]?) async throws -> T {
        if Demo.isOn {
            return try JSONDecoder().decode(T.self, from: Demo.answer(method, path, body: body))
        }
        if Relay.isPaired {
            let (status, data) = try await Relay.call(method, path, body: body)
            guard (200..<300).contains(status) else {
                throw BridgeError(message: (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "Your Mac returned \(status)")
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
        guard usesDirect, let url = URL(string: baseURL + path) else {
            throw BridgeError(message: "Pair with your Mac in Settings.")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let error as URLError where error.code != .cancelled {
            throw BridgeError(message: error.code == .notConnectedToInternet
                ? "Your watch is offline."
                : "Can't reach your Mac. It may be asleep or offline.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            switch status {
            case 401: throw BridgeError(message: "Your Mac didn't accept the pairing token. Check Settings.")
            case 502, 503, 504, 530: throw BridgeError(message: "Your Mac isn't answering. It may be asleep, or the bridge has stopped.")
            default: throw BridgeError(message: message ?? "Bridge returned \(status)")
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
