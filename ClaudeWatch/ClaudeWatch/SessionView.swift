import AVFoundation
import SwiftUI
import WatchKit

/// Reads text aloud through the watch speaker or connected headphones.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if speaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        try? session.setActive(true)
        speaking = true
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}

extension String {
    /// A stable colour per session, so the same session looks the same in the list and when open.
    var sessionColor: Color {
        let hash = unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 1)
    }

    /// Renders inline markdown (bold, code) instead of showing the raw symbols.
    var asMarkdown: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: self, options: options)) ?? AttributedString(self)
    }
}

struct SessionView: View {
    let route: SessionRoute

    @Environment(\.scenePhase) private var scenePhase
    @State private var detail: SessionDetail?
    @State private var error: String?
    @State private var sending = false
    @State private var wasRunning = false
    @State private var sentAnswer = false
    /// Set when a reply moved the conversation to a watch copy of a session open on the Mac.
    @State private var copyID: String?
    @StateObject private var speaker = Speaker()

    private var running: Bool { sending || detail?.state == "running" }
    private var sessionID: String { copyID ?? route.id }
    private var busyOnMac: Bool { detail?.state == "active" }
    private var openOnMac: Bool { detail?.state == "open" }
    private var isCopy: Bool { detail?.watchCopy == true }
    private var turns: [Turn] { Array((detail?.turns ?? []).suffix(4)) }
    private var color: Color { route.id.sessionColor }

    /// What the read-aloud button speaks: Claude's last message, plus any question it is waiting on.
    private var spokenText: String {
        var parts: [String] = []
        if let last = detail?.turns.last(where: { $0.role == "assistant" }) {
            parts.append(String(last.text.asMarkdown.characters))
        }
        if let choices = detail?.choices, !running {
            if !choices.question.isEmpty { parts.append(choices.question) }
            parts.append("Options: " + choices.options.joined(separator: ", or "))
        }
        return parts.joined(separator: ". ")
    }

    var body: some View {
        VStack(spacing: 4) {
        header
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                        Bubble(turn: turn, color: color).id(index)
                    }
                    if let pending = detail?.pending {
                        Bubble(turn: Turn(role: "user", text: pending.prompt), color: color)
                    }
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().frame(width: 18, height: 18)
                            Text(detail?.canStop == false ? "Working on your Mac…" : "Claude is working…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .id("working")
                    } else if detail == nil && error == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    if let waiting = detail?.waitingOnMac {
                        Label(waiting, systemImage: "desktopcomputer")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let error = error ?? detail?.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    if let choices = detail?.choices, !running {
                        ChoicesView(choices: choices, color: color) { option in
                            Task { await send(option) }
                        }
                        .id("choices")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
            }
            // Opens at the latest message, not the oldest.
            .defaultScrollAnchor(.bottom)
            .onChange(of: detail?.turns) { old, _ in showLatest(proxy, animated: old != nil) }
            .onChange(of: running) { _, _ in showLatest(proxy, animated: true) }
        }
        }
        .navigationTitle(detail?.project ?? "Session")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if running && detail?.canStop == false {
                    // Running on the Mac: it can be read aloud, but only stopped there.
                    Button {
                        speaker.toggle(spokenText)
                    } label: {
                        Image(systemName: speaker.speaking ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .disabled(spokenText.isEmpty)
                    Spacer()
                } else if running {
                    Spacer()
                    Button(role: .destructive) {
                        Task { await run { try await Bridge.stop(sessionID) } }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(sending)
                    Spacer()
                } else {
                    Button {
                        speaker.toggle(spokenText)
                    } label: {
                        Image(systemName: speaker.speaking ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .disabled(spokenText.isEmpty)
                    Spacer()
                    TextFieldLink(prompt: Text("Message \(detail?.title ?? route.title)")) {
                        Image(systemName: "mic.fill")
                    } onSubmit: { text in
                        Task { await send(text) }
                    }
                    .foregroundStyle(color)
                }
            }
        }
        .onDisappear { speaker.stop() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            if let answer = route.answer, !sentAnswer {
                // Tapped on a notification: send it now that the app is in front.
                sentAnswer = true
                await send(answer)
            }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(running ? 2 : 10))
            }
        }
    }

    /// Stays pinned at the top so it is always clear which session this is.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if running || busyOnMac {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(running ? .orange : .green)
                }
                Text(detail?.title ?? route.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if isCopy {
                Text("Watch copy · not shown on Mac").font(.system(size: 10)).foregroundStyle(.secondary)
            } else if openOnMac || busyOnMac {
                Text(busyOnMac ? "Busy on Mac · it reads your message between steps" : "Open on Mac · messages go to the live session").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Brings the newest message into view: its start, so a long reply reads from the top.
    private func showLatest(_ proxy: ScrollViewProxy, animated: Bool) {
        // After this layout pass, so the new message has a position to scroll to.
        DispatchQueue.main.async {
            withAnimation(animated ? .default : nil) {
                if running {
                    proxy.scrollTo("working", anchor: .bottom)
                } else if !turns.isEmpty {
                    proxy.scrollTo(turns.count - 1, anchor: .top)
                }
            }
        }
    }

    private func refresh() async {
        do {
            let fresh = try await Bridge.session(sessionID)
            let isRunning = fresh.state == "running"
            if wasRunning && !isRunning {
                WKInterfaceDevice.current().play(fresh.error == nil ? .success : .failure)
            }
            wasRunning = isRunning
            detail = fresh
            error = nil
        } catch where error.isCancellation {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func send(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        sending = true
        await run {
            let answering = try await Bridge.send(text, to: sessionID)
            if answering != sessionID {
                copyID = answering
                wasRunning = false
            }
        }
        sending = false
    }

    private func run(_ action: () async throws -> Void) async {
        do {
            try await action()
            WKInterfaceDevice.current().play(.click)
            await refresh()
        } catch {
            self.error = error.localizedDescription
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

/// One message: yours on the right in the session colour, Claude's on the left.
struct Bubble: View {
    let turn: Turn
    let color: Color

    private var mine: Bool { turn.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mine ? "You" : "Claude")
                .font(.caption2)
                .foregroundStyle(mine ? color : .secondary)
            Text(turn.text.asMarkdown)
                .font(mine ? .footnote : .body)
                .lineLimit(mine ? 4 : nil)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(mine ? color.opacity(0.22) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(mine ? .leading : .trailing, 14)
    }
}

/// A question from Claude with one button per answer; tapping sends that answer.
struct ChoicesView: View {
    let choices: Choices
    let color: Color
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !choices.question.isEmpty {
                Text(choices.question.asMarkdown)
                    .font(.footnote.weight(.semibold))
            }
            ForEach(choices.options, id: \.self) { option in
                Button {
                    pick(option)
                } label: {
                    Text(option)
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(color)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
