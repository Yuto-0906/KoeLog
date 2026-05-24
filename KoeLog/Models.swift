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
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var transcript: String
    var audioFileName: String
    var duration: TimeInterval
    var modelName: String
    var statusRawValue: String
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        transcript: String = "",
        audioFileName: String,
        duration: TimeInterval,
        modelName: String = GeminiTranscriptionClient.defaultModel,
        status: TranscriptionStatus = .pendingUpload,
        errorMessage: String? = nil
    ) {
        self.id = id
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
}

struct PendingTranscriptionJob: Codable, Identifiable, Equatable {
    var id: UUID
    var recordID: UUID
    var audioFileName: String
    var duration: TimeInterval
    var modelName: String
    var status: TranscriptionStatus
    var uploadedFileURI: String?
    var updatedAt: Date
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
