//
//  Models.swift
//  KoeLog
//

import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable, CaseIterable {
    case pendingUpload
    case uploading
    case generating
    case completed
    case failed

    var label: String {
        switch self {
        case .pendingUpload:
            "送信待ち"
        case .uploading:
            "アップロード中"
        case .generating:
            "文字起こし中"
        case .completed:
            "完了"
        case .failed:
            "失敗"
        }
    }

    var isRunning: Bool {
        self == .pendingUpload || self == .uploading || self == .generating
    }
}

@Model
final class TranscriptRecord {
    var id: UUID = UUID()
    var title: String?
    var createdAt: Date = Date()
    var transcript: String = ""
    var audioFileName: String = ""
    var duration: TimeInterval = 0
    var modelName: String = GeminiTranscriptionClient.defaultModel
    var statusRawValue: String = TranscriptionStatus.pendingUpload.rawValue
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        title: String? = nil,
        createdAt: Date = Date(),
        transcript: String = "",
        audioFileName: String,
        duration: TimeInterval,
        modelName: String = GeminiTranscriptionClient.defaultModel,
        status: TranscriptionStatus = .pendingUpload,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.transcript = transcript
        self.audioFileName = audioFileName
        self.duration = duration
        self.modelName = modelName
        self.statusRawValue = status.rawValue
        self.errorMessage = errorMessage
    }

    var status: TranscriptionStatus {
        get { TranscriptionStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }

    var audioURL: URL {
        AudioFileStore.recordingsDirectory.appendingPathComponent(audioFileName)
    }

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        return "録音 \(createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct PendingTranscriptionJob: Codable, Identifiable, Equatable {
    var id: UUID
    var recordID: UUID
    var audioFileName: String
    var duration: TimeInterval
    var modelName: String
    var languageIDs: [String]?
    var status: TranscriptionStatus
    var uploadedFileURI: String?
    var updatedAt: Date
}

enum TranscriptionLanguage: String, Codable, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"
    case chinese = "zh"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case italian = "it"
    case vietnamese = "vi"
    case thai = "th"
    case indonesian = "id"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .japanese:
            "日本語"
        case .english:
            "英語"
        case .chinese:
            "中国語"
        case .korean:
            "韓国語"
        case .spanish:
            "スペイン語"
        case .french:
            "フランス語"
        case .german:
            "ドイツ語"
        case .portuguese:
            "ポルトガル語"
        case .italian:
            "イタリア語"
        case .vietnamese:
            "ベトナム語"
        case .thai:
            "タイ語"
        case .indonesian:
            "インドネシア語"
        }
    }
}

enum TranscriptionLanguageStore {
    private static let selectedLanguagesKey = "selected-transcription-languages"
    static let fallbackLanguageIDs = [TranscriptionLanguage.japanese.id]

    static func selectedLanguageIDs() -> Set<String> {
        let saved = UserDefaults.standard.stringArray(forKey: selectedLanguagesKey) ?? fallbackLanguageIDs
        let validIDs = Set(TranscriptionLanguage.allCases.map(\.id))
        let filtered = Set(saved.filter { validIDs.contains($0) })
        return filtered.isEmpty ? Set(fallbackLanguageIDs) : filtered
    }

    static func saveSelectedLanguageIDs(_ languageIDs: Set<String>) {
        let validIDs = Set(TranscriptionLanguage.allCases.map(\.id))
        let filtered = languageIDs.filter { validIDs.contains($0) }
        let stored = filtered.isEmpty ? fallbackLanguageIDs : Array(filtered).sorted()
        UserDefaults.standard.set(stored, forKey: selectedLanguagesKey)
    }

    static func languages(for languageIDs: [String]?) -> [TranscriptionLanguage] {
        let ids = Set(languageIDs ?? Array(selectedLanguageIDs()))
        let languages = TranscriptionLanguage.allCases.filter { ids.contains($0.id) }
        return languages.isEmpty ? [.japanese] : languages
    }
}

struct GeminiModelInfo: Codable, Identifiable, Hashable {
    var id: String
    var displayName: String

    var label: String {
        displayName.isEmpty || displayName == id ? id : "\(displayName) (\(id))"
    }
}

enum GeminiModelStore {
    private static let selectedModelKey = "selected-gemini-model"
    private static let availableModelsKey = "available-gemini-models"

    static let fallbackModels = [
        GeminiModelInfo(id: GeminiTranscriptionClient.defaultModel, displayName: "Gemini 2.5 Flash")
    ]

    static func selectedModelName() -> String {
        let saved = UserDefaults.standard.string(forKey: selectedModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved! : GeminiTranscriptionClient.defaultModel
    }

    static func saveSelectedModelName(_ modelName: String) {
        let normalized = GeminiTranscriptionClient.normalizedModelName(modelName)
        UserDefaults.standard.set(normalized, forKey: selectedModelKey)
    }

    static func availableModels() -> [GeminiModelInfo] {
        guard let data = UserDefaults.standard.data(forKey: availableModelsKey),
              let models = try? JSONDecoder().decode([GeminiModelInfo].self, from: data),
              !models.isEmpty else {
            return fallbackModels
        }
        return models
    }

    static func saveAvailableModels(_ models: [GeminiModelInfo]) {
        guard let data = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(data, forKey: availableModelsKey)
    }
}

enum AudioFileStore {
    static var recordingsDirectory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newRecordingURL() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return recordingsDirectory.appendingPathComponent("koelog-\(timestamp).m4a")
    }

    static func deleteRecording(named fileName: String) {
        let url = recordingsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }
}

enum ExportFileStore {
    static func transcriptTextURL(for record: TranscriptRecord) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KoeLogExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(baseFileName(for: record)).txt")
        try record.transcript.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private static func baseFileName(for record: TranscriptRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "koelog-\(formatter.string(from: record.createdAt))"
    }
}
