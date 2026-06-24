import Foundation
import Cocoa

enum DebugLogger {
    private static var fileHandle: FileHandle?
    private static var isEnabled = false

    static func configure(enabled: Bool) {
        isEnabled = enabled
        if enabled {
            setupLogFile()
        } else {
            fileHandle?.closeFile()
            fileHandle = nil
        }
    }

    static func log(_ message: String) {
        guard AppSettings.shared.debugMode else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")

        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    static func openLogFile() {
        let logURL = logFileURL()
        NSWorkspace.shared.open(logURL)
    }

    private static func setupLogFile() {
        let url = logFileURL()
        let dir = url.deletingLastPathComponent()

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    private static func logFileURL() -> URL {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryURL.appendingPathComponent("Logs/Jot/debug.log")
    }
}
