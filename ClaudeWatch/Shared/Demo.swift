import Foundation

/// A pretend Mac, for App Review and screenshots: entering the code 000 000 when pairing turns it
/// on. It answers the same API as the bridge with sample sessions, entirely on the watch.
enum Demo {
    static let code = "000000"

    static var isOn: Bool {
        get { Bridge.shared.bool(forKey: "demoMode") }
        set { Bridge.shared.set(newValue, forKey: "demoMode") }
    }

    private struct Session {
        let id: String
        let title: String
        let project: String
        let state: String
        let minutesAgo: Double
        var turns: [[String: String]]
        var choices: [String: Any]?
    }

    // Messages sent in this run, so a reply shows up the way it would from a real Mac.
    nonisolated(unsafe) private static var sent: [String: [[String: String]]] = [:]

    private static var sessions: [Session] {
        [
            Session(id: "00000000-0000-4000-8000-000000000001", title: "Add dark mode to settings", project: "web-app",
                    state: "open", minutesAgo: 2,
                    turns: [["role": "user", "text": "Add a dark mode toggle to the settings page"],
                            ["role": "assistant", "text": "Added the toggle and a theme hook. Should it follow the system setting by default?"]],
                    choices: ["question": "Follow the system setting by default?", "options": ["Yes, follow system", "No, start light"]]),
            Session(id: "00000000-0000-4000-8000-000000000002", title: "Fix flaky checkout test", project: "shop-api",
                    state: "active", minutesAgo: 0.5,
                    turns: [["role": "user", "text": "The checkout test fails about one run in ten. Find out why."],
                            ["role": "assistant", "text": "Reproduced it: the test races the payment webhook. Adding a wait for the order state now."]]),
            Session(id: "00000000-0000-4000-8000-000000000003", title: "Write release notes for 2.4", project: "mobile",
                    state: "idle", minutesAgo: 95,
                    turns: [["role": "user", "text": "Draft release notes for 2.4 from the merged PRs"],
                            ["role": "assistant", "text": "Drafted RELEASE_NOTES.md: offline mode, faster sync, and 12 fixes. Ready for your review."]]),
            Session(id: "00000000-0000-4000-8000-000000000004", title: "Upgrade to the new SDK", project: "infra",
                    state: "idle", minutesAgo: 60 * 26,
                    turns: [["role": "user", "text": "Upgrade the services to the new SDK version"],
                            ["role": "assistant", "text": "All 6 services upgraded and tests pass. Two deprecated calls were replaced."]]),
        ]
    }

    /// Answers one API call like the bridge would. Returns the JSON body.
    static func answer(_ method: String, _ path: String, body: [String: Any]?) throws -> Data {
        let now = Date.now.timeIntervalSince1970
        let parts = path.split(separator: "/").map(String.init)

        if path == "/status" {
            return try json([
                "needsYou": 1, "working": 1, "idle": 2,
                "top": ["id": sessions[0].id, "title": sessions[0].title, "question": "Follow the system setting by default?"],
                "usage": ["session": ["used": 0.42, "resetsAt": now + 2 * 3600],
                          "week": ["used": 0.27, "resetsAt": now + 4 * 86400]],
            ])
        }
        if path == "/sessions" && method == "GET" {
            return try json(["sessions": sessions.map { s in
                [
                    "id": s.id, "title": s.title, "project": s.project, "state": s.state,
                    "updatedAt": now - s.minutesAgo * 60, "preview": s.turns.last?["text"] ?? "",
                    "needsYou": s.choices != nil && sent[s.id] == nil, "watchCopy": false,
                ] as [String: Any]
            }])
        }
        if path == "/sessions" && method == "POST" {
            // "New session": a sample one that answers at once.
            let text = body?["text"] as? String ?? ""
            let id = "00000000-0000-4000-8000-0000000000\(String(format: "%02d", 10 + sent.count))"
            sent[id] = [["role": "user", "text": text], ["role": "assistant", "text": reply(to: text)]]
            return try json(["id": id, "title": text])
        }
        if parts.count == 3, parts[0] == "sessions", parts[2] == "message" {
            let text = body?["text"] as? String ?? ""
            sent[parts[1], default: []] += [["role": "user", "text": text], ["role": "assistant", "text": reply(to: text)]]
            return try json(["id": parts[1]])
        }
        if parts.count == 2, parts[0] == "sessions" {
            let id = parts[1]
            let extra = sent[id] ?? []
            if let s = sessions.first(where: { $0.id == id }) {
                return try json([
                    "id": id, "title": s.title, "project": s.project, "state": extra.isEmpty ? s.state : "open",
                    "turns": s.turns + extra, "choices": extra.isEmpty ? (s.choices as Any? ?? NSNull()) : NSNull(),
                    "watchCopy": false, "canStop": false,
                ])
            }
            return try json([
                "id": id, "title": extra.first?["text"] ?? "New session", "project": "demo", "state": "idle",
                "turns": extra, "watchCopy": false, "canStop": false,
            ])
        }
        throw BridgeError(message: "Not available in the demo")
    }

    private static func reply(to text: String) -> String {
        "This is the demo, so nothing ran. Paired with your Mac, the Claude Code session would do this and answer here: \(text)"
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }
}
