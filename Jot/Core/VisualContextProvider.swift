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
    private let cacheSeconds: TimeInterval = 15.0

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
        guard let caret = caretRect else {
            return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        // 480×200 window around caret — enough context, minimal GPU work
        let w: CGFloat = 480, h: CGFloat = 200
        let x = max(0, caret.origin.x - w * 0.25)
        let y = max(0, caret.origin.y - h * 0.55)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private nonisolated static func runOCR(on image: CGImage, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { req, err in
            guard err == nil,
                  let obs = req.results as? [VNRecognizedTextObservation] else {
                completion(nil); return
            }
            let lines = obs.compactMap { o -> String? in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
                return c.string
            }
            let text = lines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text.isEmpty ? nil : text)
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) }
        catch { completion(nil) }
    }
}
