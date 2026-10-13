import Foundation

/// The "Save only" destination: nothing is sent anywhere; the link is the recording's file URL.
public actor LocalSaver: VideoUploader {
    public init() {}

    public func upload(
        file: URL, title: String, context: UploadContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
            size > 0
        else {
            throw UploadError.fileUnreadable
        }
        progress(1)
        return UploadResult(link: file)
    }
}
