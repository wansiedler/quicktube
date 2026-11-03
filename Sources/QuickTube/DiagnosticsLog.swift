import Foundation
import QuickTubeCore

/// Append-only text log for upload and recording diagnostics: ~/Library/Logs/QuickTube/quicktube.log
enum DiagnosticsLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Logs/QuickTube")
    static let url = directory.appending(path: "quicktube.log")

    private static let lock = NSLock()
    /// Touched under `lock`: whether a failed write was reported to the system log already.
    nonisolated(unsafe) private static var reportedFailure = false

    /// At launch: creates the log directory and writes a "launched" line, so the file exists (and
    /// menu → Open Log File works) before anything else is logged.
    static func start() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        append("QuickTube \(version)\(build.map { " (\($0))" } ?? "") launched")
    }

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        // Last line of defence: no bot token reaches the log file, whatever the caller formatted.
        let data = Data("\(stamp) \(TelegramUploader.redact(line))\n".utf8)
        lock.withLock {
            do {
                try write(data)
                reportedFailure = false
            } catch {
                // Once per outage, so a broken log location does not flood the system log.
                guard !reportedFailure else { return }
                reportedFailure = true
                NSLog("QuickTube: cannot write \(url.path): \(error)")
            }
        }
    }

    /// Runs under `lock`. Creates the directory when it is missing (also after it was deleted).
    private static func write(_ data: Data) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
