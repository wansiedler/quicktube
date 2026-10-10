import Foundation

/// The file operations cleanup needs; fakeable in tests.
public protocol RecordingFiles: Sendable {
    /// Every regular file in `directory` with its modification date. A missing directory has none.
    func recordings(in directory: URL) throws -> [(url: URL, modified: Date)]
    /// Moves the file to the Trash.
    func trash(_ url: URL) throws
}

/// Moves recordings to the Trash: the uploaded one right after upload, old ones at launch.
public struct RecordingCleanup: Sendable {
    private let files: RecordingFiles
    private let now: @Sendable () -> Date

    public init(files: RecordingFiles, now: @escaping @Sendable () -> Date = { Date() }) {
        self.files = files
        self.now = now
    }

    /// Trashes finished recordings (`.mp4`) last modified more than `days` days ago and returns them.
    /// `days <= 0` trashes nothing. Segments (`*.segN.mp4`) and Telegram copies (`*.telegram.mp4`) belong to
    /// the recorder and transcoder and are skipped. A file that cannot be trashed is skipped too.
    @discardableResult
    public func trashOlder(than days: Int, in directory: URL) throws -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now().addingTimeInterval(-TimeInterval(days) * 86400)
        var trashed: [URL] = []
        for (url, modified) in try files.recordings(in: directory)
        where Self.isRecording(url) && modified < cutoff {
            do {
                try files.trash(url)
                trashed.append(url)
            } catch {
                continue
            }
        }
        return trashed
    }

    /// Trashes the uploaded file; the caller logs a failure.
    public func trashAfterUpload(_ file: URL) throws {
        try files.trash(file)
    }

    static func isRecording(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mp4" else { return false }
        let stem = url.deletingPathExtension()
        if stem.pathExtension.lowercased() == "telegram" { return false }
        let tag = stem.pathExtension.lowercased()
        if tag.hasPrefix("seg"), tag.count > 3, tag.dropFirst(3).allSatisfy(\.isNumber) { return false }
        return true
    }
}

/// `FileManager`-backed; trashing is reversible from Finder.
public struct DefaultRecordingFiles: RecordingFiles {
    public init() {}

    public func recordings(in directory: URL) throws -> [(url: URL, modified: Date)] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let urls = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        return urls.compactMap { url in
            guard
                let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else { return nil }
            return (url, date)
        }
    }

    public func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
