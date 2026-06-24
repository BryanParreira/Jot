import Foundation

/// userData tag placed on every CGEventSource we create for synthetic keystrokes.
/// The event tap checks this so it never intercepts its own injected events.
enum SynthesizedEventMarker {
    static let userData: Int64 = 0x4A6F7453796E7468  // "JotSynth" ASCII bytes
}
