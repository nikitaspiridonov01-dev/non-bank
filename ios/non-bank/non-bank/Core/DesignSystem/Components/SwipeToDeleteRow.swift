import SwiftUI
import UIKit

/// A row that supports native-feeling swipe-to-delete via a UIKit pan gesture.
struct SwipeToDeleteRow<Content: View>: UIViewControllerRepresentable {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SwipeToDeleteHostController<Content> {
        SwipeToDeleteHostController(onDelete: onDelete, rootView: content())
    }

    func updateUIViewController(_ controller: SwipeToDeleteHostController<Content>, context: Context) {
        controller.updateContent(content())
    }
}

class SwipeToDeleteHostController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private var hostController: UIHostingController<Content>
    private let onDelete: () -> Void
    private var deleteButton: UIButton!
    private var contentLeading: NSLayoutConstraint!
    private var deleteWidth: NSLayoutConstraint!
    private let deleteButtonWidth: CGFloat = 80
    private var isRevealed = false

    init(onDelete: @escaping () -> Void, rootView: Content) {
        self.onDelete = onDelete
        self.hostController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateContent(_ rootView: Content) {
        hostController.rootView = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        view.backgroundColor = .clear

        deleteButton = UIButton(type: .system)
        deleteButton.backgroundColor = .systemRed
        let trashImage = UIImage(systemName: "trash.fill")?.withRenderingMode(.alwaysTemplate)
        deleteButton.setImage(trashImage, for: .normal)
        deleteButton.tintColor = .white
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(deleteButton)

        addChild(hostController)
        hostController.view.backgroundColor = .clear
        hostController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostController.view)
        hostController.didMove(toParent: self)

        contentLeading = hostController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        deleteWidth = deleteButton.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            contentLeading,
            hostController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostController.view.widthAnchor.constraint(equalTo: view.widthAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            deleteButton.topAnchor.constraint(equalTo: view.topAnchor),
            deleteButton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            deleteWidth
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

        switch gesture.state {
        case .changed:
            let newOffset: CGFloat
            if isRevealed {
                newOffset = min(0, max(-deleteButtonWidth + translation.x, -deleteButtonWidth * 1.5))
            } else {
                newOffset = min(0, translation.x)
            }
            contentLeading.constant = newOffset
            deleteWidth.constant = abs(newOffset)

        case .ended, .cancelled:
            let shouldReveal: Bool
            if isRevealed {
                shouldReveal = !(translation.x > deleteButtonWidth * 0.4 || velocity.x > 300)
            } else {
                shouldReveal = contentLeading.constant < -deleteButtonWidth * 0.4 || velocity.x < -300
            }

            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.5) {
                self.contentLeading.constant = shouldReveal ? -self.deleteButtonWidth : 0
                self.deleteWidth.constant = shouldReveal ? self.deleteButtonWidth : 0
                self.view.layoutIfNeeded()
            }
            isRevealed = shouldReveal

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

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) * 1.2
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return false
    }
}
