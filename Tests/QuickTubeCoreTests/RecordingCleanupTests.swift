import Foundation
import QuickTubeCore
import Testing

private final class FakeRecordingFiles: RecordingFiles, @unchecked Sendable {
    var files: [(url: URL, modified: Date)] = []
    var trashed: [URL] = []
    var trashError: Error?

    func recordings(in directory: URL) throws -> [(url: URL, modified: Date)] { files }

    func trash(_ url: URL) throws {
        if let trashError { throw trashError }
        trashed.append(url)
    }
}

@Suite struct RecordingCleanupTests {
    private let now = Date(timeIntervalSince1970: 100 * 86400)
    private let directory = URL(filePath: "/rec")

    private func file(_ name: String, daysAgo: Double) -> (url: URL, modified: Date) {
        (directory.appending(path: name), now.addingTimeInterval(-daysAgo * 86400))
    }

    private func cleanup(_ files: FakeRecordingFiles) -> RecordingCleanup {
        let now = now
        return RecordingCleanup(files: files, now: { now })
    }

    @Test func trashesOnlyRecordingsOlderThanTheLimit() throws {
        let files = FakeRecordingFiles()
        files.files = [
            file("old.mp4", daysAgo: 31), file("edge.mp4", daysAgo: 30), file("new.mp4", daysAgo: 1),
        ]
        let trashed = try cleanup(files).trashOlder(than: 30, in: directory)
        #expect(trashed == [directory.appending(path: "old.mp4")])
        #expect(files.trashed == trashed)
    }

    @Test func zeroDaysTrashesNothing() throws {
        let files = FakeRecordingFiles()
        files.files = [file("old.mp4", daysAgo: 500)]
        #expect(try cleanup(files).trashOlder(than: 0, in: directory).isEmpty)
        #expect(try cleanup(files).trashOlder(than: -3, in: directory).isEmpty)
        #expect(files.trashed.isEmpty)
    }

    @Test func skipsIntermediateAndNonMp4Files() throws {
        let files = FakeRecordingFiles()
        files.files = [
            file("a.seg1.mp4", daysAgo: 90), file("a.seg12.mp4", daysAgo: 90),
            file("a.telegram.mp4", daysAgo: 90), file("notes.txt", daysAgo: 90),
            file("clip.mov", daysAgo: 90), file("keep.MP4", daysAgo: 90),
            file("my.segment.mp4", daysAgo: 90),
        ]
        let trashed = try cleanup(files).trashOlder(than: 7, in: directory)
        #expect(
            trashed.map(\.lastPathComponent).sorted() == ["keep.MP4", "my.segment.mp4"])
    }

    @Test func oneFailureDoesNotStopTheRest() throws {
        final class FlakyFiles: RecordingFiles, @unchecked Sendable {
            var trashed: [URL] = []
            let list: [(url: URL, modified: Date)]
            init(_ list: [(url: URL, modified: Date)]) { self.list = list }
            func recordings(in directory: URL) throws -> [(url: URL, modified: Date)] { list }
            func trash(_ url: URL) throws {
                if url.lastPathComponent == "bad.mp4" { throw CocoaError(.fileWriteNoPermission) }
                trashed.append(url)
            }
        }
        let flaky = FlakyFiles([file("bad.mp4", daysAgo: 40), file("good.mp4", daysAgo: 40)])
        let now = now
        let trashed = try RecordingCleanup(files: flaky, now: { now }).trashOlder(than: 7, in: directory)
        #expect(trashed == [directory.appending(path: "good.mp4")])
    }

    @Test func trashAfterUploadTrashesExactlyThatFile() throws {
        let files = FakeRecordingFiles()
        let target = directory.appending(path: "Talk.mp4")
        try cleanup(files).trashAfterUpload(target)
        #expect(files.trashed == [target])
    }

    @Test func trashAfterUploadPropagatesErrors() {
        let files = FakeRecordingFiles()
        files.trashError = CocoaError(.fileWriteNoPermission)
        #expect(throws: CocoaError.self) {
            try cleanup(files).trashAfterUpload(directory.appending(path: "a.mp4"))
        }
    }

    @Test func defaultFilesListsMp4WithModifiedDateAndTrashes() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "qt-clean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appending(path: "a.mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data([0]))
        let listed = try DefaultRecordingFiles().recordings(in: dir)
        #expect(listed.map(\.url.lastPathComponent) == ["a.mp4"])
        #expect(abs(listed[0].modified.timeIntervalSinceNow) < 60)
    }

    @Test func defaultFilesOnMissingDirectoryIsEmpty() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "qt-none-\(UUID().uuidString)")
        #expect(try DefaultRecordingFiles().recordings(in: missing).isEmpty)
    }
}
