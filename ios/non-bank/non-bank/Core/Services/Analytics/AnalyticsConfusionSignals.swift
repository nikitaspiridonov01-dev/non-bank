import SwiftUI

// MARK: - Confusion Signals
//
// Wrappers that turn ambient "user is frustrated / lost" interactions
// into typed `AnalyticsEvent`s without forcing every call-site to
// maintain its own timers or counters.
//
// What's tracked:
//   - Rage tap: ≥3 taps on the same logical element within ~800ms.
//     Proxy for "this control didn't do what I expected so I'm
//     mashing it." Wrap the affected button with `.rageTapTracked`.
//   - Flow abandonment: a flow (modal, multi-step wizard) opens,
//     the user dwells, then closes without committing. Drive via
//     `AnalyticsFlowSession` started on open and ended on close —
//     calling `complete()` means success; not calling it means
//     abandonment is fired on deinit / scope exit.
//
// What's NOT tracked here (intentionally):
//   - Scroll-without-action (too noisy to capture cleanly in SwiftUI)
//   - Specific gesture failures (those bubble up as `form_validation_
//     failed` from the form layer where the validation rule lives)

// MARK: - Rage-tap detector

/// State held per-tracked element. Resets after a quiet period so
/// the next burst is a fresh count.
@MainActor
final class RageTapState {
    private let element: String
    private let analytics: AnalyticsServiceProtocol
    /// Minimum gap between taps that breaks the streak. 800ms is
    /// "the user paused to think" vs <800ms = "user mashing."
    private let windowMs: Int = 800
    /// Minimum taps in window to consider it a rage tap. 3 is the
    /// sweet spot — 2 has false positives (deliberate double-tap),
    /// 4+ misses some real frustration bursts.
    private let threshold: Int = 3

    private var lastTapAt: Date?
    private var streakCount: Int = 0

    init(element: String, analytics: AnalyticsServiceProtocol) {
        self.element = element
        self.analytics = analytics
    }

    func recordTap() {
        let now = Date()
        if let last = lastTapAt {
            let gapMs = Int(now.timeIntervalSince(last) * 1000)
            if gapMs < windowMs {
                streakCount += 1
            } else {
                streakCount = 1
            }
        } else {
            streakCount = 1
        }
        lastTapAt = now

        if streakCount >= threshold {
            analytics.track(.rageTapDetected(element: element, tapCount: streakCount))
            // Reset so the next event needs a fresh burst rather
            // than re-firing on every subsequent tap.
            streakCount = 0
            lastTapAt = nil
        }
    }
}

private struct RageTapTrackerModifier: ViewModifier {
    let element: String
    @Environment(\.analytics) private var analytics
    @State private var state: RageTapState?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        if state == nil {
                            state = RageTapState(element: element, analytics: analytics)
                        }
                        state?.recordTap()
                    }
            )
    }
}

extension View {
    /// Wrap a tappable element to track rage taps (3+ taps within
    /// ~800ms). Apply on candidate buttons that have caused user
    /// confusion in past sessions — don't wrap every button (it
    /// would just inflate event volume without signal).
    func rageTapTracked(_ element: String) -> some View {
        modifier(RageTapTrackerModifier(element: element))
    }
}

// MARK: - Flow abandonment session

/// Token returned when a multi-step flow opens. Call `complete()`
/// from the success path; if scope exits without `complete()` being
/// called, `flow_abandoned` is fired with the last `markStep` value
/// + dwell time.
///
/// Note: relies on deterministic deinit. SwiftUI `@State` wraps it
/// in a stable reference so going out of scope after the view
/// dismisses fires the deinit reliably.
@MainActor
final class AnalyticsFlowSession {
    private let flow: AnalyticsFlow
    private let analytics: AnalyticsServiceProtocol
    private let openedAt: Date
    private var currentStep: String
    private var didComplete: Bool = false

    init(flow: AnalyticsFlow, atStep: String, analytics: AnalyticsServiceProtocol) {
        self.flow = flow
        self.analytics = analytics
        self.openedAt = Date()
        self.currentStep = atStep
    }

    /// Update the step name as the user advances. The latest value
    /// is what `flow_abandoned` reports if the session is dropped
    /// without `complete()`.
    func markStep(_ step: String) {
        currentStep = step
    }

    /// Call from the success path. After this, deinit becomes a
    /// no-op — the flow completed, no abandonment fires.
    func complete() {
        didComplete = true
    }

    deinit {
        guard !didComplete else { return }
        let dwell = Date().timeIntervalSince(openedAt)
        analytics.track(.flowAbandoned(
            flow: flow,
            atStep: currentStep,
            dwellSecondsBucket: AnalyticsBuckets.dwellSeconds(dwell)
        ))
    }
}

extension AnalyticsServiceProtocol {
    /// Start tracking a flow for abandonment. Hand the returned
    /// session to a `@State` property on the view so its lifetime
    /// matches the flow's. Call `complete()` from your success
    /// path; otherwise the deinit fires `flow_abandoned`.
    func startFlow(_ flow: AnalyticsFlow, atStep: String) -> AnalyticsFlowSession {
        AnalyticsFlowSession(flow: flow, atStep: atStep, analytics: self)
    }
}
