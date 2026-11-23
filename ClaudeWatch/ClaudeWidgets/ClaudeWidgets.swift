import SwiftUI
import WidgetKit

// Watch face complications and Smart Stack cards for Claude sessions and usage.
// watchOS decides when these refresh (roughly every 15 minutes); the app asks for a
// refresh whenever it is opened or a "needs you" notification arrives.

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: BridgeStatus?
    /// True when the Mac couldn't be reached and this is the last status that arrived.
    var stale = false

    /// Rises in the Smart Stack while a session is waiting on you.
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: (status?.needsYou ?? 0) > 0 ? 100 : 1)
    }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, status: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        if context.isPreview { return completion(placeholder(in: context)) }
        Task { completion(await StatusProvider.current()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await StatusProvider.current()
            // Ask again sooner while something is happening, or soon if the Mac didn't answer.
            let busy = (entry.status?.needsYou ?? 0) + (entry.status?.working ?? 0) > 0
            let minutes: Double = entry.stale ? 5 : busy ? 10 : 20
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(minutes * 60))))
        }
    }

    /// Fresh from the Mac, or the last known status for up to two hours when it can't be reached.
    static func current() async -> StatusEntry {
        if let status = try? await Bridge.status() {
            return StatusEntry(date: .now, status: status)
        }
        if let last = Bridge.lastStatus, Date.now.timeIntervalSince(last.at) < 2 * 60 * 60 {
            return StatusEntry(date: .now, status: last.status, stale: true)
        }
        return StatusEntry(date: .now, status: nil)
    }
}

/// Lets the bridge ask watchOS to reload the watch face the moment a session changes.
struct WatchFacePush: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = pushInfo.token.map { String(format: "%02x", $0) }.joined()
        Task { try? await Bridge.registerDevice(token, sandbox: Bridge.pushSandbox, kind: "widgets") }
    }
}

// MARK: - Sessions

struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sessions", provider: StatusProvider()) { entry in
            SessionsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(entry.status?.top.map { AppLink.session($0.id) } ?? AppLink.home)
        }
        .pushHandler(WatchFacePush.self)
        .configurationDisplayName("Sessions")
        .description("What your sessions are doing, and which one needs you.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}

struct SessionsWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let status = entry.status {
            switch family {
            case .accessoryCircular: circular(status)
            case .accessoryInline: inline(status)
            case .accessoryCorner: corner(status)
            default: rectangular(status)
            }
        } else {
            Label("Mac offline", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private func rectangular(_ s: BridgeStatus) -> some View {
        if let top = s.top {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.bubble.fill")
                    Text(s.needsYou > 1 ? "\(s.needsYou) need you" : "Needs you")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .widgetAccentable()
                Text(top.title).font(.headline).lineLimit(1)
                Text(top.question).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.stale ? "Claude · a while ago" : "Claude").font(.caption2.weight(.semibold)).foregroundStyle(.orange).widgetAccentable()
                row("circle.fill", "\(s.working) working", .orange)
                row("circle", "\(s.idle) idle", .secondary)
                if let usage = s.usage?.headline {
                    Text("\(percent(usage.used)) of limit used").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 7)).foregroundStyle(color)
            Text(text).font(.caption)
        }
    }

    private func circular(_ s: BridgeStatus) -> some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: s.needsYou > 0 ? "exclamationmark.bubble.fill" : "bubble.left.and.bubble.right")
                    .font(.system(size: 13))
                    .widgetAccentable()
                Text("\(s.needsYou > 0 ? s.needsYou : s.working)")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(s.needsYou > 0 ? .orange : .primary)
        }
    }

    private func inline(_ s: BridgeStatus) -> some View {
        if s.needsYou > 0 {
            Text("Claude · \(s.needsYou) needs you")
        } else {
            Text("Claude · \(s.working) working")
        }
    }

    private func corner(_ s: BridgeStatus) -> some View {
        Image(systemName: s.needsYou > 0 ? "exclamationmark.bubble.fill" : "bubble.left.and.bubble.right")
            .font(.title3)
            .foregroundStyle(s.needsYou > 0 ? .orange : .primary)
            .widgetAccentable()
            .widgetLabel(s.needsYou > 0 ? "\(s.needsYou) need you" : "\(s.working) working")
    }
}

// MARK: - Usage

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "usage", provider: StatusProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(AppLink.home)
        }
        .pushHandler(WatchFacePush.self)
        .configurationDisplayName("Usage")
        .description("How much of your usage limit is spent.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct UsageWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let usage = entry.status?.usage, let head = usage.headline {
            switch family {
            case .accessoryCircular:
                Gauge(value: head.used) {
                    Image(systemName: "sparkle")
                } currentValueLabel: {
                    Text(percentNumber(head.used))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(tint(head.used))
            case .accessoryCorner:
                Text(percent(head.used))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .widgetCurvesContent()
                    .widgetLabel {
                        Gauge(value: head.used) { Text("Claude") }
                            .tint(tint(head.used))
                    }
            case .accessoryInline:
                Text("Claude \(percent(head.used)) · resets \(head.resetDate, style: .relative)")
            default:
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude usage").font(.caption2.weight(.semibold)).foregroundStyle(.orange).widgetAccentable()
                    if let session = usage.session { bar("Session", session) }
                    if let week = usage.week { bar("This week", week) }
                    if let fable = usage.fable { bar("Fable", fable) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            switch family {
            case .accessoryCircular:
                ZStack { AccessoryWidgetBackground(); Image(systemName: "sparkle") }
            default:
                Text(entry.status == nil ? "Mac offline" : "Usage not known yet").font(.caption2)
            }
        }
    }

    private func bar(_ label: String, _ w: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label)
                Spacer()
                Text(percent(w.used))
            }
            .font(.caption2)
            ProgressView(value: w.used).tint(tint(w.used))
        }
    }

    private func tint(_ used: Double) -> Color {
        used >= 0.9 ? .red : used >= 0.7 ? .orange : .green
    }
}

private func percent(_ used: Double) -> String { "\(percentNumber(used))%" }
private func percentNumber(_ used: Double) -> String { "\(Int((min(max(used, 0), 1) * 100).rounded()))" }

@main
struct ClaudeWidgetBundle: WidgetBundle {
    var body: some Widget {
        SessionsWidget()
        UsageWidget()
    }
}
