import SwiftUI
import UserNotifications
import WatchKit

/// Notification categories the bridge sends, and turning a tapped button into an answer.
enum Alerts {
    static let needsYou = "needs-you"   // a question; its answers are added per alert
    static let done = "done"            // finished a stretch of work
    static let onMac = "on-mac"         // a dialog only the Mac can answer, like a permission prompt
    static let replyID = "reply"
    static let optionPrefix = "option."

    static var reply: UNTextInputNotificationAction {
        // .foreground: watchOS doesn't give an app network access when a button runs it in the background.
        UNTextInputNotificationAction(identifier: replyID, title: "Reply", options: [.foreground],
                                      textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
    }

    static var categories: Set<UNNotificationCategory> {
        [
            // The buttons for a question are set by NeedsYouNotificationController; Reply is the fallback.
            UNNotificationCategory(identifier: needsYou, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: done, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: onMac, actions: [], intentIdentifiers: []),
        ]
    }

    /// The text to send for the button that was tapped, or nil when the alert itself was tapped.
    static func answer(in response: UNNotificationResponse) -> String? {
        if let typed = response as? UNTextInputNotificationResponse {
            let text = typed.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        let action = response.actionIdentifier
        guard action.hasPrefix(optionPrefix), let index = Int(action.dropFirst(optionPrefix.count)),
              let options = response.notification.request.content.userInfo["options"] as? [String],
              options.indices.contains(index) else { return nil }
        return options[index]
    }
}

/// The long look for a question: the question, with each answer as a button under it.
final class NeedsYouNotificationController: WKUserNotificationHostingController<NeedsYouNotificationView> {
    private var title = ""
    private var question = ""

    override var body: NeedsYouNotificationView {
        NeedsYouNotificationView(title: title, question: question)
    }

    override func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        title = content.title
        question = content.body
        let options = (content.userInfo["options"] as? [String]) ?? []
        notificationActions = options.prefix(4).enumerated().map { index, option in
            UNNotificationAction(identifier: "\(Alerts.optionPrefix)\(index)", title: option, options: [.foreground])
        } + [Alerts.reply]
        // watchOS asks for `body` after this returns, so the view picks up the fields set above.
    }
}

struct NeedsYouNotificationView: View {
    let title: String
    let question: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Needs you", systemImage: "exclamationmark.bubble.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
            Text(title).font(.headline).lineLimit(2)
            Text(question.asMarkdown).font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
