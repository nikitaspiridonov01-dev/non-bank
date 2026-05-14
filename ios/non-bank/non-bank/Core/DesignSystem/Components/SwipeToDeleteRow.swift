import SwiftUI
import UIKit

/// Configures the optional leading-swipe affordance on
/// `SwipeToDeleteRow`. The `iconSystemName` is rendered on a tinted
/// pill so the user can visually tell it apart from the destructive
/// delete button — no red, no trash. `iconSystemName` flips between
/// two glyphs based on the current state (e.g. `eye.slash` vs `eye`).
///
/// Declared at module scope (not nested inside `SwipeToDeleteRow`) so
/// callers can spell its type without supplying the generic `Content`
/// argument — the row's content type is irrelevant to the action's
/// shape.
struct SwipeRowLeadingAction {
    let iconSystemName: String
    let tint: UIColor
    let onTap: () -> Void
}

/// A row that supports native-feeling swipe-to-delete via a UIKit pan gesture.
/// Optionally also exposes a leading-swipe (right swipe) action — used by
/// transaction rows for the "hide from insights" affordance the user
/// asked for, sitting alongside (but visually distinct from) the
/// destructive trailing-swipe delete.
struct SwipeToDeleteRow<Content: View>: UIViewControllerRepresentable {
    let onDelete: () -> Void
    /// Optional right-swipe action. When nil, leading-swipe is disabled
    /// and the row behaves exactly like the original delete-only variant.
    let leadingAction: SwipeRowLeadingAction?
    @ViewBuilder let content: () -> Content

    init(
        onDelete: @escaping () -> Void,
        leadingAction: SwipeRowLeadingAction? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onDelete = onDelete
        self.leadingAction = leadingAction
        self.content = content
    }

    func makeUIViewController(context: Context) -> SwipeToDeleteHostController<Content> {
        SwipeToDeleteHostController(
            onDelete: onDelete,
            leadingAction: leadingAction,
            rootView: content()
        )
    }

    func updateUIViewController(_ controller: SwipeToDeleteHostController<Content>, context: Context) {
        controller.updateContent(content())
        controller.updateLeadingAction(leadingAction)
    }
}

class SwipeToDeleteHostController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private var hostController: UIHostingController<Content>
    private let onDelete: () -> Void
    private var leadingAction: SwipeRowLeadingAction?
    private var deleteButton: UIButton!
    private var leadingButton: UIButton!
    private var contentLeading: NSLayoutConstraint!
    private var deleteWidth: NSLayoutConstraint!
    private var leadingWidth: NSLayoutConstraint!
    private let actionButtonWidth: CGFloat = 80
    /// Tracks which side is revealed: 0 = none, -1 = trailing delete,
    /// +1 = leading custom action. Replaces the old boolean so the pan
    /// handler can disambiguate "swiping out from delete" vs "swiping
    /// out from leading action" on overshoot.
    private var revealedDirection: Int = 0

    init(
        onDelete: @escaping () -> Void,
        leadingAction: SwipeRowLeadingAction?,
        rootView: Content
    ) {
        self.onDelete = onDelete
        self.leadingAction = leadingAction
        self.hostController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateContent(_ rootView: Content) {
        hostController.rootView = rootView
    }

    /// Refresh the leading-button glyph + tint without rebuilding the
    /// view — the icon flips between "hide" and "show" as the user's
    /// flag changes, and we want the next swipe to pick up the new
    /// state without tearing down the controller.
    func updateLeadingAction(_ action: SwipeRowLeadingAction?) {
        self.leadingAction = action
        guard let leadingButton else { return }
        if let action {
            leadingButton.backgroundColor = action.tint
            let image = UIImage(systemName: action.iconSystemName)?.withRenderingMode(.alwaysTemplate)
            leadingButton.setImage(image, for: .normal)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.backgroundColor = .clear

        deleteButton = UIButton(type: .system)
        // Use the design-system `danger` token instead of `.systemRed`
        // so swipe-to-delete picks up the wine/rose hue that's
        // visually distinct from `reminderAccent` (warm calendar-red).
        deleteButton.backgroundColor = UIColor(AppColors.danger)
        let trashImage = UIImage(systemName: "trash.fill")?.withRenderingMode(.alwaysTemplate)
        deleteButton.setImage(trashImage, for: .normal)
        deleteButton.tintColor = .white
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deleteButton)

        leadingButton = UIButton(type: .system)
        leadingButton.tintColor = .white
        leadingButton.addTarget(self, action: #selector(leadingTapped), for: .touchUpInside)
        leadingButton.translatesAutoresizingMaskIntoConstraints = false
        // Initial glyph picked up from leadingAction (nil-safe — when
        // the row was created without a leading action the button
        // still exists but has zero width and never reveals).
        if let action = leadingAction {
            leadingButton.backgroundColor = action.tint
            let image = UIImage(systemName: action.iconSystemName)?.withRenderingMode(.alwaysTemplate)
            leadingButton.setImage(image, for: .normal)
        }
        view.addSubview(leadingButton)

        addChild(hostController)
        hostController.view.backgroundColor = .clear
        hostController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostController.view)
        hostController.didMove(toParent: self)

        contentLeading = hostController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        deleteWidth = deleteButton.widthAnchor.constraint(equalToConstant: 0)
        leadingWidth = leadingButton.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            contentLeading,
            hostController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostController.view.widthAnchor.constraint(equalTo: view.widthAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            deleteButton.topAnchor.constraint(equalTo: view.topAnchor),
            deleteButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            deleteWidth,
            leadingButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            leadingButton.topAnchor.constraint(equalTo: view.topAnchor),
            leadingButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leadingWidth
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        hostController.view.addGestureRecognizer(pan)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preferredContentSize = hostController.view.intrinsicContentSize
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let supportsLeading = leadingAction != nil

        switch gesture.state {
        case .changed:
            // Two reveal directions. From a closed state, sign of the
            // translation picks which side opens. From an already-
            // revealed state, the relevant button stays anchored while
            // the user drags the content back.
            let newOffset: CGFloat
            switch revealedDirection {
            case -1: // trailing delete revealed
                newOffset = min(0, max(-actionButtonWidth + translation.x, -actionButtonWidth * 1.5))
            case 1 where supportsLeading: // leading action revealed
                newOffset = max(0, min(actionButtonWidth + translation.x, actionButtonWidth * 1.5))
            default:
                // Closed: clamp to the side that's allowed. Trailing
                // (delete) is always allowed; leading only when a
                // leading action was supplied.
                if translation.x < 0 {
                    newOffset = translation.x
                } else if supportsLeading {
                    newOffset = translation.x
                } else {
                    newOffset = 0
                }
            }
            contentLeading.constant = newOffset
            if newOffset < 0 {
                deleteWidth.constant = abs(newOffset)
                leadingWidth.constant = 0
            } else {
                leadingWidth.constant = newOffset
                deleteWidth.constant = 0
            }

        case .ended, .cancelled:
            let shouldReveal: Int
            switch revealedDirection {
            case -1:
                let close = translation.x > actionButtonWidth * 0.4 || velocity.x > 300
                shouldReveal = close ? 0 : -1
            case 1 where supportsLeading:
                let close = translation.x < -actionButtonWidth * 0.4 || velocity.x < -300
                shouldReveal = close ? 0 : 1
            default:
                if contentLeading.constant < -actionButtonWidth * 0.4 || velocity.x < -300 {
                    shouldReveal = -1
                } else if supportsLeading,
                          contentLeading.constant > actionButtonWidth * 0.4 || velocity.x > 300 {
                    shouldReveal = 1
                } else {
                    shouldReveal = 0
                }
            }

            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5) {
                switch shouldReveal {
                case -1:
                    self.contentLeading.constant = -self.actionButtonWidth
                    self.deleteWidth.constant = self.actionButtonWidth
                    self.leadingWidth.constant = 0
                case 1:
                    self.contentLeading.constant = self.actionButtonWidth
                    self.leadingWidth.constant = self.actionButtonWidth
                    self.deleteWidth.constant = 0
                default:
                    self.contentLeading.constant = 0
                    self.deleteWidth.constant = 0
                    self.leadingWidth.constant = 0
                }
                self.view.layoutIfNeeded()
            }
            revealedDirection = shouldReveal

        default:
            break
        }
    }

    @objc private func deleteTapped() {
        UIView.animate(withDuration: 0.25, animations: {
            self.contentLeading.constant = -self.view.bounds.width
            self.view.layoutIfNeeded()
            self.view.alpha = 0
        }) { _ in
            self.onDelete()
        }
    }

    /// Non-destructive — collapse the row back to closed and fire the
    /// callback. Caller's handler typically mutates the transaction's
    /// `excludedFromInsights` flag; the row stays put so the user can
    /// see the new state (or undo it).
    @objc private func leadingTapped() {
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5) {
            self.contentLeading.constant = 0
            self.deleteWidth.constant = 0
            self.leadingWidth.constant = 0
            self.view.layoutIfNeeded()
        } completion: { _ in
            self.revealedDirection = 0
            self.leadingAction?.onTap()
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return false
    }
}
