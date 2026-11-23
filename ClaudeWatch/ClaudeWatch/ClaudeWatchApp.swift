import SwiftUI
import UserNotifications
import WatchKit
import WidgetKit

@main
struct ClaudeWatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // `-showPairing` opens the pairing screen directly, for screenshots in the simulator.
            if ProcessInfo.processInfo.arguments.contains("-showPairing") {
                NavigationStack { PairView() }
            } else {
                SessionsView().environmentObject(Router.shared)
            }
            #else
            SessionsView().environmentObject(Router.shared)
            #endif
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
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo") { Demo.isOn = true } // simulator screenshots
        if let i = args.firstIndex(of: "-open"), i + 1 < args.count {
            Task { @MainActor in Router.shared.open = SessionRoute(id: args[i + 1], title: "Session") }
        }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Alerts.categories)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-showPairing") || ProcessInfo.processInfo.arguments.contains("-demo") { return } // screenshots: no permission prompt
        #endif
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
    @State private var showOlder = false

    private var current: [SessionSummary] { sessions.filter { $0.older != true } }
    private var older: [SessionSummary] { sessions.filter { $0.older == true } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // New session and usage, side by side.
                HStack(spacing: 6) {
                    TextFieldLink(prompt: Text("Ask Claude, or \"Tell harness to…\"")) {
                        VStack(spacing: 3) {
                            Image(systemName: "plus.bubble.fill").font(.title3)
                            Text("New").font(.footnote.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(Color.blue.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    } onSubmit: { text in
                        Task { await startSession(text) }
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        UsageView(usage: status?.usage)
                    } label: {
                        UsageTile(usage: status?.usage)
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))

                if !Bridge.isConfigured {
                    NavigationLink {
                        PairView()
                    } label: {
                        Label("Pair with your Mac", systemImage: "link")
                    }
                    .listItemTint(.orange)
                } else if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                ForEach(current) { session in
                    NavigationLink(value: SessionRoute(id: session.id, title: session.title)) {
                        SessionRow(session: session)
                    }
                }

                // Archived, deleted and old sessions, out of the way until asked for.
                if !older.isEmpty {
                    Button {
                        withAnimation { showOlder.toggle() }
                    } label: {
                        Label(showOlder ? "Hide older" : "Show \(older.count) older", systemImage: showOlder ? "chevron.up" : "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if showOlder {
                        ForEach(older) { session in
                            NavigationLink(value: SessionRoute(id: session.id, title: session.title)) {
                                SessionRow(session: session).opacity(0.7)
                            }
                        }
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
                    Text(session.project).lineLimit(1).layoutPriority(1)
                    Text("·")
                    Text(Date(timeIntervalSince1970: session.updatedAt), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .lineLimit(1)
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

/// Usage as small rings next to the New button: the weekly total, and Fable's own limit when the
/// account has one (else the 5-hour session limit). Tap for the details.
struct UsageTile: View {
    let usage: UsageInfo?

    private var rings: [(label: String, window: UsageWindow?)] {
        guard let usage else { return [("Week", nil)] }
        var out: [(String, UsageWindow?)] = [("All", usage.week)]
        if let fable = usage.fable { out.append(("Fable", fable)) }
        else if let session = usage.session { out.append(("5 hr", session)) }
        return out
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(rings, id: \.label) { ring in
                VStack(spacing: 1) {
                    Gauge(value: min(max(ring.window?.used ?? 0, 0), 1)) {
                        EmptyView()
                    } currentValueLabel: {
                        Text(ring.window.map { "\(Int(($0.used * 100).rounded()))" } ?? "–")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(usageColor(ring.window?.used ?? 0))
                    .scaleEffect(rings.count > 1 ? 0.62 : 0.8)
                    .frame(height: 36)
                    Text(ring.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

func usageColor(_ used: Double) -> Color {
    used >= 0.9 ? .red : used >= 0.7 ? .orange : .green
}

/// Usage details: every limit, with when it resets.
struct UsageView: View {
    let usage: UsageInfo?

    var body: some View {
        ScrollView {
            if let usage, usage.headline != nil {
                UsageRow(usage: usage)
            } else {
                Text("Your Mac hasn't reported usage yet.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Usage")
    }
}

/// How much of your usage limits is spent.
struct UsageRow: View {
    let usage: UsageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session = usage.session { bar("Session limit", session) }
            if let week = usage.week { bar("This week, all models", week) }
            if let fable = usage.fable { bar("This week, Fable", fable) }
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
                .tint(usageColor(w.used))
            Text("Resets \(w.resetDate, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @AppStorage("relayURL", store: Bridge.shared) private var relayURL = ""
    @AppStorage("baseURL", store: Bridge.shared) private var baseURL = ""
    @AppStorage("token", store: Bridge.shared) private var token = ""
    @State private var pairing = Relay.pairing
    @State private var demo = Demo.isOn
    @State private var confirmUnpair = false
    @State private var confirmRotate = false
    @State private var note: String?

    var body: some View {
        Form {
            if demo {
                Section {
                    Text("Showing sample sessions.")
                    Button("Leave the demo") {
                        Demo.isOn = false
                        demo = false
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                } header: {
                    Text("Demo")
                }
            }
            Section {
                if let pairing, pairing.confirmed {
                    LabeledContent("Paired with", value: pairing.macName)
                    Button("Unpair", role: .destructive) { confirmUnpair = true }
                } else {
                    NavigationLink("Pair with your Mac") { PairView() }
                }
                TextField(Relay.defaultURL.isEmpty ? "Relay https://…" : Relay.defaultURL, text: $relayURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote)
            } footer: {
                Text("Pairing goes through the relay above, encrypted end to end between this watch and your Mac. Change it only if you run your own.")
            }

            Section {
                TextField("https://…", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Pairing token", text: $token)
                if Bridge.usesDirect {
                    Button("New pairing token") { confirmRotate = true }
                }
                if let note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Direct connection")
            } footer: {
                Text("Only if you run your own tunnel instead of pairing. Used while this watch isn't paired.")
            }
        }
        .navigationTitle("Settings")
        .onAppear { pairing = Relay.pairing }
        .confirmationDialog("Unpair from \(pairing?.macName ?? "your Mac")?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) {
                Task {
                    await Relay.unpair()
                    pairing = nil
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
        .confirmationDialog("Change the pairing token?", isPresented: $confirmRotate) {
            Button("Change token", role: .destructive) { Task { await rotate() } }
        } message: {
            Text("Anything else using the old token loses access.")
        }
    }

    private func rotate() async {
        do {
            try await Bridge.rotateToken()
            note = "Done. The old token no longer works."
            WKInterfaceDevice.current().play(.success)
        } catch {
            note = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

/// Pairs this watch with a Mac: enter the code the Mac shows, compare check numbers, confirm on the Mac.
struct PairView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("relayURL", store: Bridge.shared) private var relayURL = ""
    @State private var code = ""
    @State private var check: String?
    @State private var working = false
    @State private var error: String?
    @State private var paired = false

    private var relay: String { relayURL.isEmpty ? Relay.defaultURL : relayURL }

    var body: some View {
        Group {
            if paired {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                    Text("Paired").font(.headline)
                }
            } else if let check {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Check number").font(.caption).foregroundStyle(.secondary)
                        Text(check)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("If your Mac shows the same number, type y there and press Return.")
                            .font(.footnote)
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Entering the code: the pad fills the screen, nothing to scroll.
                VStack(spacing: 3) {
                    Group {
                        if let error {
                            Text(error).foregroundStyle(.red).lineLimit(2).minimumScaleFactor(0.7)
                        } else if relay.isEmpty {
                            Text("Set a relay in Settings first.").foregroundStyle(.orange)
                        } else {
                            Text("Code from your Mac").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    CodePad(code: $code, working: working) { Task { await join() } }
                }
                // The keys use the screen down to its rounded bottom edge.
                .padding(.bottom, 6)
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle("Pair")
        .toolbarTitleDisplayMode(.inline)
        .task(id: check) {
            // Wait for the person to confirm on the Mac.
            guard check != nil else { return }
            while !Task.isCancelled && !paired {
                if let status = try? await Relay.status(), status.confirmed {
                    paired = true
                    WKInterfaceDevice.current().play(.success)
                    await Bridge.reregisterDevices()
                    WidgetCenter.shared.reloadAllTimelines()
                    try? await Task.sleep(for: .seconds(1.5))
                    dismiss()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func join() async {
        if code == Demo.code {
            // For App Review and screenshots: sample sessions, no Mac needed.
            Demo.isOn = true
            paired = true
            WKInterfaceDevice.current().play(.success)
            WidgetCenter.shared.reloadAllTimelines()
            try? await Task.sleep(for: .seconds(1))
            dismiss()
            return
        }
        guard code.count == 6, !relay.isEmpty, !working else { return }
        working = true
        defer { working = false }
        error = nil
        do {
            check = try await Relay.join(code: code, relayURL: relay.trimmingCharacters(in: .whitespaces))
        } catch {
            code = ""
            self.error = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

/// Six digits on a compact number pad that fits the screen. Sends the code once the sixth is in.
struct CodePad: View {
    @Binding var code: String
    let working: Bool
    let done: () -> Void

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Text(code.isEmpty ? "––– –––" : formatted)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(working ? 0.3 : 1)
                if working { ProgressView().scaleEffect(0.6) }
            }
            .frame(height: 24)
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { key in
                        if key.isEmpty {
                            Color.clear
                        } else {
                            Button { press(key) } label: {
                                Text(key)
                                    .font(.system(size: 20, weight: .medium, design: .rounded))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .disabled(working)
    }

    private var formatted: String {
        code.count > 3 ? "\(code.prefix(3)) \(code.dropFirst(3))" : code
    }

    private func press(_ key: String) {
        WKInterfaceDevice.current().play(.click)
        if key == "⌫" {
            if !code.isEmpty { code.removeLast() }
            return
        }
        guard code.count < 6 else { return }
        code += key
        if code.count == 6 { done() }
    }
}
