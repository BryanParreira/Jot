import Foundation

/// Chooses the prediction debounce from the last observed generation latency.
///
/// A fixed debounce serves two masters badly: on fast hardware it adds avoidable delay before
/// every suggestion, and on slow hardware it lets keystrokes pile doomed generations onto a model
/// that cannot keep up (each cancel still costs a decode setup and teardown). Keying the debounce
/// to the most recent generation latency makes fast machines snappier and slow machines calmer,
/// with no configuration. The configured value remains the fallback until a first latency exists.
nonisolated enum DebouncePolicy {
    /// Chooses the debounce window from two signals:
    ///
    /// **Generation latency** — keeps fast hardware snappy and slow hardware calm.
    /// No point firing more often than the model can respond, and no point waiting longer
    /// than needed when decode is already fast.
    ///
    /// **Typing speed (inter-keystroke interval)** — avoids wasting a generation mid-burst.
    /// When keys come quickly (< 100ms apart), the user is still typing; adding a small hold
    /// reduces the number of doomed generations cancelled a keystroke later. When the user
    /// pauses (> 350ms), they are thinking — trigger faster so the suggestion appears the
    /// moment they stop, not after another fixed wait.
    static func milliseconds(
        lastGenerationLatencyMilliseconds: Int?,
        interKeystrokeMilliseconds: Int? = nil,
        fallback: Int
    ) -> Int {
        let latencyBase: Int
        if let last = lastGenerationLatencyMilliseconds, last > 0 {
            switch last {
            case ...70: latencyBase = 15
            case ...140: latencyBase = 25
            default: latencyBase = 55
            }
        } else {
            latencyBase = fallback
        }

        let typingAdjustment: Int
        if let iks = interKeystrokeMilliseconds {
            switch iks {
            case ...100:
                // Rapid burst — user mid-word or mid-phrase; hold a bit longer.
                typingAdjustment = 25
            default:
                // Normal or paused pacing — no adjustment. We deliberately do not cut the wait
                // on pause so suggestions do not fire during idle moments between keystrokes.
                typingAdjustment = 0
            }
        } else {
            typingAdjustment = 0
        }

        return max(0, latencyBase + typingAdjustment)
    }
}
