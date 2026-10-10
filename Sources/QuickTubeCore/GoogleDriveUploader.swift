import Foundation

public enum DriveError: Error, Equatable {
    /// The token lacks `drive.file`; the user signed in before Drive support existed.
    case insufficientScope
    case badResponse(Int)
}

/// Uploads into a "QuickTube" folder in the user's Drive and makes the file viewable by link.
public actor GoogleDriveUploader: VideoUploader {
    public static let folderName = "QuickTube"

    private let tokens: TokenProvider
    private let session: URLSession
    private let apiBase: URL
    private let uploadBase: URL
    private let log: @Sendable (String) -> Void
    private var folderID: String?

    public init(
        tokens: TokenProvider,
        session: URLSession = .shared,
        apiBase: URL = URL(string: "https://www.googleapis.com/drive/v3")!,
        uploadBase: URL = URL(string: "https://www.googleapis.com/upload/drive/v3")!,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.tokens = tokens
        self.session = session
        self.apiBase = apiBase
        self.uploadBase = uploadBase
        self.log = log
    }

    public func upload(
        file: URL, title: String, context: UploadContext = UploadContext(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> UploadResult {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw UploadError.fileUnreadable }
        let folder = try await ensureFolder()
        let sessionURL = try await createSession(title: title, size: size, folder: folder)

        var put = try await authorized(URLRequest(url: sessionURL))
        put.httpMethod = "PUT"
        put.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (body, response) = try await session.upload(
            for: put, fromFile: file, delegate: ProgressDelegate(progress))
        let http = try check(response, body: body, expecting: [200, 201])
        _ = http
        let uploaded = try JSONDecoder().decode(DriveFile.self, from: body)
        try await shareByLink(fileID: uploaded.id)
        progress(1)
        let link = uploaded.webViewLink ?? URL(string: "https://drive.google.com/file/d/\(uploaded.id)/view")!
        return UploadResult(link: link)
    }

    // MARK: - Steps

    private struct DriveFile: Decodable {
        let id: String
        let webViewLink: URL?
    }

    private struct FileList: Decodable {
        let files: [DriveFile]
    }

    private func ensureFolder() async throws -> String {
        if let folderID { return folderID }
        let query =
            "name = '\(Self.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        var components = URLComponents(url: apiBase.appending(path: "files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "spaces", value: "drive"),
        ]
        let lookup = try await authorized(URLRequest(url: components.url!))
        let (listBody, listResponse) = try await session.data(for: lookup)
        _ = try check(listResponse, body: listBody, expecting: [200])
        if let existing = try JSONDecoder().decode(FileList.self, from: listBody).files.first {
            folderID = existing.id
            return existing.id
        }
        var create = try await authorized(URLRequest(url: apiBase.appending(path: "files")))
        create.httpMethod = "POST"
        create.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONEncoder().encode(
            ["name": Self.folderName, "mimeType": "application/vnd.google-apps.folder"])
        let (body, response) = try await session.data(for: create)
        _ = try check(response, body: body, expecting: [200])
        let created = try JSONDecoder().decode(DriveFile.self, from: body)
        folderID = created.id
        return created.id
    }

    private struct Metadata: Encodable {
        let name: String
        let mimeType: String
        let parents: [String]
    }

    private func createSession(title: String, size: Int, folder: String) async throws -> URL {
        var components = URLComponents(
            url: uploadBase.appending(path: "files"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id,webViewLink"),
        ]
        var request = try await authorized(URLRequest(url: components.url!))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONEncoder().encode(
            Metadata(name: "\(title).mp4", mimeType: "video/mp4", parents: [folder]))
        let (body, response) = try await session.data(for: request)
        let http = try check(response, body: body, expecting: [200])
        guard let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location)
        else {
            throw UploadError.missingSessionURL
        }
        return url
    }

    private func shareByLink(fileID: String) async throws {
        var request = try await authorized(
            URLRequest(url: apiBase.appending(path: "files/\(fileID)/permissions")))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["role": "reader", "type": "anyone"])
        let (body, response) = try await session.data(for: request)
        _ = try check(response, body: body, expecting: [200])
    }

    // MARK: - Helpers

    private func authorized(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    @discardableResult
    private func check(_ response: URLResponse, body: Data, expecting: Set<Int>) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw DriveError.badResponse(0) }
        guard expecting.contains(http.statusCode) else {
            let text = String(decoding: body.prefix(4000), as: UTF8.self)
            log("Drive HTTP \(http.statusCode) \(http.url?.absoluteString ?? "") \(text)")
            if http.statusCode == 403, text.contains("insufficient") || text.contains("SCOPE") {
                throw DriveError.insufficientScope
            }
            throw YouTubeUploader.error(status: http.statusCode, body: body)
        }
        return http
    }
}
