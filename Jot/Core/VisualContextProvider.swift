import Cocoa
import Vision

/// Captures a screenshot around the caret and runs on-device OCR (Vision framework)
/// to extract visible text as context for LLM completions.
///
/// Results cache for 3 s so OCR doesn't re-run on every keystroke.
@MainActor
class VisualContextProvider {
    static let shared = VisualContextProvider()

    private var cachedText: String?
    private var lastCaptureDate: Date?
    private let cacheSeconds: TimeInterval = 4.0  // 4s: fresh enough to reflect recent edits

    private init() {}

    // MARK: - Permission

    func isPermissionGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Main API

    /// Returns OCR-extracted text visible around the caret, or nil if unavailable.
    func context(caretRect: CGRect?) async -> String? {
        guard AppSettings.shared.screenAwareMode,
              isPermissionGranted(),
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical
        else { return nil }

        // Return cached result if still fresh
        if let lastDate = lastCaptureDate,
           Date().timeIntervalSince(lastDate) < cacheSeconds,
           let cached = cachedText {
            return cached
        }

        let region = captureRegion(around: caretRect)
        guard let image = CGWindowListCreateImage(
            region, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]
        ) else { return nil }

        // Run Vision OCR on a background thread; suspend main actor while it works
        let capturedImage = image
        let text = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                VisualContextProvider.runOCR(on: capturedImage) { cont.resume(returning: $0) }
            }
        }

        cachedText = text
        lastCaptureDate = Date()

        DebugLogger.log("[Visual] OCR result: \(text?.prefix(80) ?? "nil")")
        return text
    }

    func invalidateCache() {
        cachedText = nil
        lastCaptureDate = nil
    }

    // MARK: - Private

    private func captureRegion(around caretRect: CGRect?) -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        guard let caret = caretRect else { return screen.frame }

        // 560×280: captures enough context (title bars, headings, surrounding text) while
        // keeping the temp CGImage allocation ~50% smaller than the prior 800×400.
        let w: CGFloat = 560, h: CGFloat = 280
        let x = max(0, min(caret.origin.x - w * 0.3, screen.frame.maxX - w))
        let y = max(0, min(caret.origin.y - h * 0.6, screen.frame.maxY - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private nonisolated static func runOCR(on image: CGImage, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { req, err in
            guard err == nil,
                  let obs = req.results as? [VNRecognizedTextObservation] else {
                completion(nil); return
            }
            let lines = obs.compactMap { o -> String? in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.45 else { return nil }
                let text = c.string
                // Drop lines with Unicode replacement glyphs (corrupted OCR)
                guard !text.contains("\u{FFFD}") else { return nil }
                // Drop lines that are mostly symbol noise (box-drawing, arrows, decorative glyphs)
                guard !VisualContextProvider.isSymbolNoiseLine(text) else { return nil }
                return text
            }
            let text = lines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text.isEmpty ? nil : text)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { completion(nil) }
    }

    /// True when more than 25% of the line's characters are uncommon symbols —
    /// box-drawing chars, arrows, icon ligatures — that corrupt LLM prompt context.
    private nonisolated static func isSymbolNoiseLine(_ text: String) -> Bool {
        let commonPunctuation: Set<Character> = [
            ".", ",", "!", "?", ";", ":", "'", "\"", "(", ")", "[", "]", "{", "}",
            "-", "/", "&", "%", "$", "#", "@", "*", "+", "=", "<", ">", "`", "~",
            "_", "|", "\\"
        ]
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return false }
        let noiseCount = scalars.filter { scalar in
            let ch = Character(scalar)
            return !ch.isLetter && !ch.isNumber && !ch.isWhitespace
                && !commonPunctuation.contains(ch)
        }.count
        return Double(noiseCount) / Double(scalars.count) > 0.25
    }
}
