import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// A reusable "spinning counter" haptic — a short burst of taps whose
/// intensity (and sharpness) ramp UP over the duration, so the save
/// feels like a mechanical counter spinning up to its new value rather
/// than a single thud.
///
/// Two backends, picked at call time:
///   1. **CoreHaptics** (preferred) — schedules a sequence of transient
///      events at rising `intensity`/`sharpness` plus a faint continuous
///      bed with a ramp-up parameter curve, for a smooth "wind-up" feel.
///   2. **Fallback** — when the device has no haptics engine
///      (`supportsHaptics == false`) or CoreHaptics fails to start, a
///      `Task`-driven sequence of `UIImpactFeedbackGenerator` taps at
///      rising intensity. Same shape, lower fidelity.
///
/// One shared CHHapticEngine instance is kept alive and lazily
/// (re)started; all start/stop/error paths are swallowed so a haptic can
/// never crash or block the UI. Safe to call from the main actor.
///
/// The total duration is tuned to match the balance count-up animation
/// on the Home screen (`BalanceCounterMotion.duration`) so the vibration
/// and the rolling number land together.
@MainActor
final class CounterHaptics {

    static let shared = CounterHaptics()

    /// Default ramp length. Kept in lockstep with the balance count-up
    /// animation so the haptic and the number finish together.
    static let defaultDuration: TimeInterval = BalanceCounterMotion.duration

    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    #endif

    /// Tracks the fallback ramp so a second save mid-ramp doesn't stack
    /// overlapping timers.
    private var fallbackTask: Task<Void, Never>?

    private init() {
        prepareEngine()
    }

    // MARK: - Public

    /// Fire the ramping "counter spin-up" haptic. `intensityFloor` and
    /// `intensityCeil` bound the ramp (≈0.3 → 1.0 by default); `ticks`
    /// is how many transient taps to lay down across `duration`.
    func playRamp(
        duration: TimeInterval = defaultDuration,
        ticks: Int = 11,
        intensityFloor: Float = 0.32,
        intensityCeil: Float = 1.0
    ) {
        #if canImport(CoreHaptics)
        if Self.supportsCoreHaptics, playCoreHapticsRamp(
            duration: duration,
            ticks: ticks,
            intensityFloor: intensityFloor,
            intensityCeil: intensityCeil
        ) {
            return
        }
        #endif
        playFallbackRamp(
            duration: duration,
            ticks: ticks,
            intensityFloor: intensityFloor,
            intensityCeil: intensityCeil
        )
    }

    // MARK: - CoreHaptics

    #if canImport(CoreHaptics)
    static var supportsCoreHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    private func prepareEngine() {
        guard Self.supportsCoreHaptics, engine == nil else { return }
        do {
            let engine = try CHHapticEngine()
            // If the engine resets (audio session interruption, etc.)
            // drop our reference so the next call rebuilds it.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.engine = nil }
            }
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil }
            }
            self.engine = engine
        } catch {
            engine = nil
        }
    }

    /// Builds and plays the ramp pattern. Returns `false` if anything
    /// fails so the caller can fall back to `UIImpactFeedbackGenerator`.
    private func playCoreHapticsRamp(
        duration: TimeInterval,
        ticks: Int,
        intensityFloor: Float,
        intensityCeil: Float
    ) -> Bool {
        prepareEngine()
        guard let engine else { return false }

        var events: [CHHapticEvent] = []

        // Faint continuous "motor" bed under the taps, fading in then out.
        let bedStart = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.12)
        let bedSharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4)
        events.append(
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [bedStart, bedSharp],
                relativeTime: 0,
                duration: duration
            )
        )

        // Rising transient taps — the "clicks" of the spinning counter.
        let count = max(ticks, 2)
        for i in 0..<count {
            // Ease-in progress so taps accelerate as intensity climbs.
            let linear = Float(i) / Float(count - 1)
            let eased = linear * linear
            let intensity = intensityFloor + (intensityCeil - intensityFloor) * eased
            let sharpness = 0.3 + 0.6 * eased
            // Taps bunch slightly tighter toward the end for the
            // "winding up" acceleration feel.
            let t = duration * Double(linear) * (0.85 + 0.15 * Double(linear))
            events.append(
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                    ],
                    relativeTime: t
                )
            )
        }

        // Ramp the continuous bed's intensity up across the burst.
        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.2),
                .init(relativeTime: duration * 0.7, value: 1.0),
                .init(relativeTime: duration, value: 0.0)
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: [curve])
            try engine.start()
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            // Engine wedged — clear it so the next attempt rebuilds, and
            // let the caller fall back.
            self.engine = nil
            return false
        }
    }
    #else
    private func prepareEngine() {}
    #endif

    // MARK: - Fallback (UIImpactFeedbackGenerator)

    private func playFallbackRamp(
        duration: TimeInterval,
        ticks: Int,
        intensityFloor: Float,
        intensityCeil: Float
    ) {
        #if canImport(UIKit)
        fallbackTask?.cancel()
        let count = max(ticks, 2)
        let floor = CGFloat(intensityFloor)
        let ceil = CGFloat(intensityCeil)
        fallbackTask = Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            for i in 0..<count {
                if Task.isCancelled { return }
                let linear = Double(i) / Double(count - 1)
                let eased = linear * linear
                let intensity = floor + (ceil - floor) * CGFloat(eased)
                generator.impactOccurred(intensity: intensity)
                generator.prepare()
                // Step toward the next tap; gaps shrink toward the end
                // to mirror the CoreHaptics acceleration.
                let gap = (duration / Double(count)) * (1.1 - 0.3 * linear)
                try? await Task.sleep(nanoseconds: UInt64(max(gap, 0.02) * 1_000_000_000))
            }
        }
        #endif
    }
}
