//
//  GeminiTranscriptionClient.swift
//  KoeLog
//

import Foundation

final class GeminiTranscriptionClient {
    static let defaultModel = "gemini-2.5-flash"

    private let apiKey: String
    private let modelName: String
    private let foregroundSession: URLSession
    private let backgroundDelegate = GeminiBackgroundSessionDelegate.shared
    private let decoder = JSONDecoder()

    init(apiKey: String, modelName: String = defaultModel) {
        self.apiKey = apiKey
        self.modelName = Self.normalizedModelName(modelName)
        self.foregroundSession = URLSession(configuration: .default)
    }

    static func normalizedModelName(_ modelName: String) -> String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private var modelResourceName: String {
        "models/\(modelName)"
    }

    func listModels() async throws -> [GeminiModelInfo] {
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "1000")
        ]

        var models: [GeminiModelInfo] = []
        var nextPageToken: String?

        repeat {
            if let nextPageToken {
                components.queryItems = [
                    URLQueryItem(name: "pageSize", value: "1000"),
                    URLQueryItem(name: "pageToken", value: nextPageToken)
                ]
            }

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

            let (data, response) = try await foregroundSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiError.invalidResponse("モデル一覧取得")
            }
            try validate(httpResponse, data: data)

            let result = try decoder.decode(GeminiListModelsResponse.self, from: data)
            models.append(contentsOf: result.models.compactMap(\.modelInfoForGenerateContent))
            nextPageToken = result.nextPageToken
        } while nextPageToken?.isEmpty == false

        let uniqueModels = Dictionary(grouping: models, by: \.id)
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending }

        return uniqueModels.isEmpty ? GeminiModelStore.fallbackModels : uniqueModels
    }

    func uploadAudioFile(at fileURL: URL) async throws -> GeminiUploadedFile {
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        let byteCount = fileSize?.intValue ?? 0
        let mimeType = "audio/mp4"

        var startRequest = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!)
        startRequest.httpMethod = "POST"
        startRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        startRequest.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startRequest.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startRequest.setValue("\(byteCount)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startRequest.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let displayName = fileURL.deletingPathExtension().lastPathComponent
        startRequest.httpBody = try JSONEncoder().encode(GeminiFileStartRequest(file: .init(displayName: displayName)))

        let (startData, startResponse) = try await foregroundSession.data(for: startRequest)
        guard let httpStartResponse = startResponse as? HTTPURLResponse else {
            throw GeminiError.invalidResponse("アップロード開始")
        }
        try validate(httpStartResponse, data: startData)

        guard let uploadURLValue = httpStartResponse.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLValue) else {
            throw GeminiError.missingUploadURL
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        uploadRequest.setValue("\(byteCount)", forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        uploadRequest.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let uploadData = try await backgroundDelegate.upload(request: uploadRequest, fileURL: fileURL)
        let response = try decoder.decode(GeminiFileUploadResponse.self, from: uploadData)
        return response.file
    }

    func generateTranscript(
        fileURI: String,
        mimeType: String = "audio/mp4",
        languages: [TranscriptionLanguage] = [.japanese]
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(modelResourceName):generateContent")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GeminiGenerateContentRequest(
                contents: [
                    .init(parts: [
                        .init(text: transcriptPrompt(for: languages)),
                        .init(fileData: .init(mimeType: mimeType, fileURI: fileURI))
                    ])
                ]
            )
        )

        let (data, response) = try await foregroundSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse("文字起こし生成")
        }
        try validate(httpResponse, data: data)

        let result = try decoder.decode(GeminiGenerateContentResponse.self, from: data)
        let text = result.candidates
            .flatMap(\.content.parts)
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw GeminiError.emptyTranscript
        }

        return text
    }

    private func transcriptPrompt(for languages: [TranscriptionLanguage]) -> String {
        let languageText = languages.map(\.label).joined(separator: "、")
        return """
        音声を正確に文字起こししてください。
        対象言語: \(languageText)
        対象言語として指定された言語の発話を優先して認識してください。
        話されている言語のまま本文のみ返してください。
        余計な説明、要約、見出し、コードブロックは返さないでください。
        """
    }

    func generateTitle(for transcript: String) async throws -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw GeminiError.emptyTranscript
        }

        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/\(modelResourceName):generateContent")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GeminiGenerateContentRequest(
                contents: [
                    .init(parts: [
                        .init(text: """
                        次の文字起こし内容にふさわしい日本語タイトルを作ってください。
                        20文字以内で、本文のみ返してください。引用符、句点、説明は不要です。

                        文字起こし:
                        \(trimmedTranscript)
                        """)
                    ])
                ]
            )
        )

        let (data, response) = try await foregroundSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse("タイトル生成")
        }
        try validate(httpResponse, data: data)

        let result = try decoder.decode(GeminiGenerateContentResponse.self, from: data)
        let title = result.candidates
            .flatMap(\.content.parts)
            .compactMap(\.text)
            .joined(separator: " ")
            .sanitizedTranscriptTitle()

        guard !title.isEmpty else {
            throw GeminiError.emptyTitle
        }

        return title
    }

    private func validate(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            if let apiError = try? decoder.decode(GeminiAPIErrorResponse.self, from: data) {
                throw GeminiError.api(apiError.error.message)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.httpStatus(response.statusCode, body)
        }
    }
}

final class GeminiBackgroundSessionDelegate: NSObject, URLSessionDataDelegate {
    static let shared = GeminiBackgroundSessionDelegate()
    private static let identifier = "com.YG.KoeLog.gemini.upload"

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var completions: [Int: CheckedContinuation<Data, Error>] = [:]
    private var buffers: [Int: Data] = [:]
    private var responses: [Int: HTTPURLResponse] = [:]
    private var backgroundCompletionHandler: (() -> Void)?
    private let lock = NSLock()

    func upload(request: URLRequest, fileURL: URL) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.lock()
            completions[task.taskIdentifier] = continuation
            buffers[task.taskIdentifier] = Data()
            lock.unlock()
            task.resume()
        }
    }

    func setBackgroundCompletionHandler(_ completionHandler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = session
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse {
            lock.lock()
            responses[dataTask.taskIdentifier] = httpResponse
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = completions.removeValue(forKey: task.taskIdentifier)
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let response = responses.removeValue(forKey: task.taskIdentifier) ?? task.response as? HTTPURLResponse
        lock.unlock()

        if let error {
            continuation?.resume(throwing: error)
            return
        }

        guard let response else {
            continuation?.resume(throwing: GeminiError.invalidResponse("音声アップロード"))
            return
        }

        guard (200..<300).contains(response.statusCode) else {
            continuation?.resume(throwing: GeminiError.httpStatus(response.statusCode, String(data: data, encoding: .utf8) ?? ""))
            return
        }

        continuation?.resume(returning: data)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()

        DispatchQueue.main.async {
            handler?()
        }
    }
}

private struct GeminiFileStartRequest: Encodable {
    struct File: Encodable {
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    let file: File
}

struct GeminiUploadedFile: Decodable {
    let name: String
    let uri: String
    let mimeType: String?

    enum CodingKeys: String, CodingKey {
        case name
        case uri
        case mimeType = "mimeType"
    }
}

private struct GeminiListModelsResponse: Decodable {
    let models: [GeminiModelResponse]
    let nextPageToken: String?
}

private struct GeminiModelResponse: Decodable {
    let name: String
    let displayName: String?
    let supportedGenerationMethods: [String]?

    var modelInfoForGenerateContent: GeminiModelInfo? {
        guard supportedGenerationMethods?.contains("generateContent") == true else {
            return nil
        }

        let id = GeminiTranscriptionClient.normalizedModelName(name)
        guard id.hasPrefix("gemini-") else {
            return nil
        }

        return GeminiModelInfo(id: id, displayName: displayName ?? id)
    }
}

private struct GeminiFileUploadResponse: Decodable {
    let file: GeminiUploadedFile
}

private struct GeminiGenerateContentRequest: Encodable {
    struct Content: Encodable {
        let parts: [Part]
    }

    struct Part: Encodable {
        var text: String? = nil
        var fileData: FileData? = nil

        enum CodingKeys: String, CodingKey {
            case text
            case fileData = "file_data"
        }
    }

    struct FileData: Encodable {
        let mimeType: String
        let fileURI: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case fileURI = "file_uri"
        }
    }

    let contents: [Content]
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        let content: Content
    }

    struct Content: Decodable {
        let parts: [Part]
    }

    struct Part: Decodable {
        let text: String?
    }

    let candidates: [Candidate]
}

private struct GeminiAPIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

enum GeminiError: LocalizedError {
    case invalidResponse(String)
    case missingUploadURL
    case emptyTranscript
    case emptyTitle
    case httpStatus(Int, String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(stage):
            "Gemini API の応答を読み取れませんでした（\(stage)）。"
        case .missingUploadURL:
            "Gemini API のアップロード URL が取得できませんでした。"
        case .emptyTranscript:
            "文字起こし本文が空でした。"
        case .emptyTitle:
            "タイトルが空でした。"
        case let .httpStatus(code, body):
            body.isEmpty ? "Gemini API エラー: HTTP \(code)" : "Gemini API エラー: HTTP \(code) \(body)"
        case let .api(message):
            "Gemini API エラー: \(message)"
        }
    }
}

private extension String {
    func sanitizedTranscriptTitle() -> String {
        let firstLine = components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」『』【】[]（）().。 "))
        return String(trimmed.prefix(30))
    }
}
