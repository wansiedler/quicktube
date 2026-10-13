import Foundation
import QuickTubeCore
import Testing

@Suite struct LocalSaverTests {
    @Test func existingFileIsTheLink() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "clip.mp4")
        try Data(count: 1024).write(to: file)
        let progress = LogLines()
        let result = try await LocalSaver().upload(
            file: file, title: "clip", context: UploadContext(),
            progress: { progress.append("\($0)") })
        #expect(result.link == file)
        #expect(result.videoID == nil)
        #expect(result.privacyStatus == nil)
        #expect(progress.all.last == "1.0")
    }

    @Test func missingFileThrows() async {
        let file = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).mp4")
        await #expect(throws: UploadError.fileUnreadable) {
            _ = try await LocalSaver().upload(
                file: file, title: "x", context: UploadContext(), progress: { _ in })
        }
    }
}
