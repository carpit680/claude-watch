import SwiftUI
import UserNotifications
import WatchKit
import WidgetKit

@main
struct ClaudeWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environmentObject(Router.shared)
        }
        // A question from a session, with its answers as buttons.
        WKNotificationScene(controller: NeedsYouNotificationController.self, category: Alerts.needsYou)
    }
}

/// Where a tapped notification or complication wants the app to go.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var open: SessionRoute?
}

/// Signs up for alerts, answers from their buttons, and opens the right session when one is tapped.
final class AppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Alerts.categories)
        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted { WKApplication.shared().registerForRemoteNotifications() }
        }
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await Bridge.registerDevice(token, sandbox: Bridge.pushSandbox) }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }

    // Shown even while the app is open, and the watch face catches up at the same time.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        WidgetCenter.shared.reloadAllTimelines()
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        WidgetCenter.shared.reloadAllTimelines()
        guard let id = info["session"] as? String else { return }
        let title = info["title"] as? String ?? "Session"

        // Open the session; an answer tapped on the alert is sent from there, with the app in front.
        await MainActor.run { Router.shared.open = SessionRoute(id: id, title: title, answer: Alerts.answer(in: response)) }
    }
}

/// Identifies a session to open, with a title to show before it loads.
struct SessionRoute: Hashable {
    let id: String
    let title: String
    /// An answer tapped on a notification, sent as soon as the session opens.
    var answer: String? = nil
}

struct SessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var router: Router
    @State private var sessions: [SessionSummary] = []
    @State private var status: BridgeStatus?
    @State private var error: String?
    @State private var loaded = false
    @State private var path: [SessionRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                TextFieldLink(prompt: Text("Ask Claude, or \"Tell harness to…\"")) {
                    Label("New session", systemImage: "plus.bubble.fill")
                } onSubmit: { text in
                    Task { await startSession(text) }
                }
                .listItemTint(.blue)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                if let usage = status?.usage, usage.headline != nil {
                    UsageRow(usage: usage)
                }

                ForEach(sessions) { session in
                    NavigationLink(value: SessionRoute(id: session.id, title: session.title)) {
                        SessionRow(session: session)
                    }
                }

                if loaded && sessions.isEmpty && error == nil {
                    Text("No sessions yet").foregroundStyle(.secondary)
                }

                NavigationLink("Settings") { SettingsView() }
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionRoute.self) { route in
                SessionView(route: route)
            }
            .overlay {
                if !loaded { ProgressView() }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else {
                    WidgetCenter.shared.reloadAllTimelines() // leave the watch face up to date
                    return
                }
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
        .onOpenURL { url in
            path = []
            if let id = AppLink.sessionID(from: url) {
                path = [SessionRoute(id: id, title: sessions.first { $0.id == id }?.title ?? "Session")]
            }
        }
        .onReceive(router.$open) { route in
            guard let route else { return }
            path = [route]
            router.open = nil
        }
    }

    private func refresh() async {
        // Both at once, so the usage bars arrive with the list instead of after it.
        async let fetchedStatus = try? Bridge.status()
        do {
            sessions = try await Bridge.sessions()
            error = nil
        } catch where error.isCancellation {
            // The app restarted its refresh (e.g. on becoming active); the next one shows the result.
        } catch {
            self.error = error.localizedDescription
        }
        if let fresh = await fetchedStatus { status = fresh }
        loaded = true
    }

    private func startSession(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let started = try await Bridge.startSession(text)
            path.append(SessionRoute(id: started.id, title: started.title))
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title).font(.headline).lineLimit(2)
                // The bar's color carries the status; this line says where and when.
                HStack(spacing: 4) {
                    if session.watchCopy == true { Image(systemName: "applewatch").font(.system(size: 9)) }
                    Text(session.project).lineLimit(1)
                    Text("·")
                    Text(Date(timeIntervalSince1970: session.updatedAt), format: .relative(presentation: .named))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Orange: needs you. Green: busy. Blue: open on the Mac. Gray: idle.
    private var statusColor: Color {
        if session.needsYou == true { return .orange }
        switch session.state {
        case "running", "active": return .green
        case "open": return .blue
        default: return .gray
        }
    }

}

/// How much of your usage limits is spent, at the top of the sessions list.
struct UsageRow: View {
    let usage: UsageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session = usage.session { bar("Session limit", session) }
            if let week = usage.week { bar("This week", week) }
        }
        .padding(.vertical, 4)
    }

    private func bar(_ label: String, _ w: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((w.used * 100).rounded()))%")
            }
            .font(.caption)
            ProgressView(value: min(max(w.used, 0), 1))
                .tint(w.used >= 0.9 ? .red : w.used >= 0.7 ? .orange : .green)
            Text("Resets \(w.resetDate, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @AppStorage("baseURL", store: Bridge.shared) private var baseURL = ""
    @AppStorage("token", store: Bridge.shared) private var token = ""
    @State private var confirmRotate = false
    @State private var rotating = false
    @State private var note: String?

    var body: some View {
        Form {
            Section("Bridge address") {
                TextField(BakedConfig.baseURL.isEmpty ? "https://…" : BakedConfig.baseURL, text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Token") {
                SecureField(BakedConfig.token.isEmpty ? "Pairing token" : "Built in", text: $token)
            }
            Section {
                Text("Leave both empty to use the values built into the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(rotating ? "Changing…" : "New pairing token") { confirmRotate = true }
                    .disabled(rotating)
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Use this if the token may have leaked. The old one stops working at once; this watch keeps working.")
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Change the pairing token?", isPresented: $confirmRotate) {
            Button("Change token", role: .destructive) { Task { await rotate() } }
        } message: {
            Text("Anything else using the old token loses access. If you reinstall the app, run configure on your Mac first.")
        }
    }

    private func rotate() async {
        rotating = true
        defer { rotating = false }
        do {
            try await Bridge.rotateToken()
            WidgetCenter.shared.reloadAllTimelines()
            note = "Done. The old token no longer works."
            WKInterfaceDevice.current().play(.success)
        } catch {
            note = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }
}
