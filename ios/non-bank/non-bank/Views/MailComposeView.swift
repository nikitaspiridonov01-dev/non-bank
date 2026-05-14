import SwiftUI
import MessageUI

/// SwiftUI wrapper for `MFMailComposeViewController`. The system mail
/// sheet (where the user picks an account / configured mail app and
/// composes the message before hitting Send) is presented as a `.sheet`.
///
/// `MFMailComposeViewController.canSendMail()` is `false` if no Mail
/// account is configured on the device; callers should check
/// `MailComposeView.canSend` before presenting and fall back to a
/// `mailto:` URL via `UIApplication.shared.open(_:)` otherwise.
struct MailComposeView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    static var canSend: Bool { MFMailComposeViewController.canSendMail() }

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            dismiss()
        }
    }
}

// MARK: - Helpers

enum SupportMail {
    static let address = "nonbankapp@gmail.com"

    enum Kind: String, CaseIterable, Identifiable {
        case feature
        case bug
        case support

        var id: String { rawValue }

        var label: String {
            switch self {
            case .feature: return "Request a feature"
            case .bug:     return "Report a bug"
            case .support: return "Contact support"
            }
        }

        var systemImage: String {
            switch self {
            case .feature: return "lightbulb"
            case .bug:     return "ladybug"
            case .support: return "questionmark.circle"
            }
        }

        var subject: String {
            switch self {
            case .feature: return "[non-bank] Feature request"
            case .bug:     return "[non-bank] Bug report"
            case .support: return "[non-bank] Support"
            }
        }

        /// Pre-filled body. We append the device + app version footer so
        /// reports come in with enough context to triage without a
        /// back-and-forth.
        func body() -> String {
            let bundle = Bundle.main
            let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            let device = UIDevice.current.model
            let os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            let footer = """


                ----
                non-bank \(version) (\(build))
                \(device) · \(os)
                """
            switch self {
            case .feature:
                return "What feature would you like to see in non-bank?\n\n" + footer
            case .bug:
                return "What happened? What did you expect to happen?\n\nSteps to reproduce:\n1.\n2.\n3.\n" + footer
            case .support:
                return "How can we help?\n\n" + footer
            }
        }

        /// `mailto:` URL fallback used when the device has no Mail account
        /// set up. Encoding is RFC 3986-strict so spaces / newlines /
        /// brackets survive.
        func mailtoURL() -> URL? {
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = SupportMail.address
            components.queryItems = [
                URLQueryItem(name: "subject", value: subject),
                URLQueryItem(name: "body", value: body())
            ]
            return components.url
        }
    }
}
