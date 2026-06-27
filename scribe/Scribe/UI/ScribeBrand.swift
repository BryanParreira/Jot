import SwiftUI

/// File overview:
/// Jot's brand palette, shared by every surface that speaks in the brand voice (onboarding,
/// the permission reminder, and the Settings Home hero). Pinned rather than derived from
/// `Color.accentColor` so brand moments stay on-brand even when the user picks a different system
/// accent; ordinary interactive controls should keep following the system accent.
enum ScribeBrand {
    /// The deep ink indigo — brand color, sampled from the quill icon (#4C33D4). Identical in both
    /// appearances.
    static let accent = Color(red: 0.298, green: 0.200, blue: 0.831)

    /// Lighter companion to `accent`, used as the top stop of icon-tile and pip gradients so
    /// tinted elements read as lit from above (the System Settings icon treatment).
    static let accentSoft = Color(red: 0.55, green: 0.45, blue: 0.95)
}
