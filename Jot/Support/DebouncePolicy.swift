import Foundation

/// Chooses prediction debounce from the last observed generation latency.
///
/// Fixed debounce serves two masters badly: on fast hardware it adds avoidable
/// delay, on slow hardware it lets keystrokes pile doomed generations onto a
/// model that can't keep up. Keying the debounce to the last latency makes fast
/// machines snappier and slow machines calmer, with no configuration.
///
/// The Ollama tier (>500ms) is added for Jot because Ollama inference on older
/// hardware routinely exceeds the latency ranges Cotabby designed for.
nonisolated enum DebouncePolicy {
    static func milliseconds(lastGenerationLatencyMilliseconds: Int?, fallback: Int) -> Int {
        guard let last = lastGenerationLatencyMilliseconds, last > 0 else {
            return fallback
        }
        switch last {
        case ...70:   return 15
        case ...140:  return 25
        case ...500:  return 55
        default:      return 150  // slow Ollama inference on older hardware
        }
    }
}
