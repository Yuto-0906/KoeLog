//
//  TranscriptViewModel.swift
//  KoeLog
//

import Foundation
import Combine
import SwiftData

@MainActor
final class TranscriptViewModel: ObservableObject {
    @Published var apiKey = ""
    @Published var apiKeySaved = false
    @Published var statusMessage = "API キーを設定し、録音を開始してください。"
    @Published var errorMessage: String?
    @Published var isProcessing = false
    @Published var selectedModelName = GeminiTranscriptionClient.defaultModel
    @Published var availableModels = GeminiModelStore.fallbackModels
    @Published var isRefreshingModels = false
    @Published var selectedLanguageIDs = Set(TranscriptionLanguageStore.fallbackLanguageIDs)

    let recorder = AudioRecorder()

    private let jobStore = TranscriptionJobStore.shared
    private let backgroundTask = BackgroundTaskController()
    private var processingRecordIDs = Set<UUID>()

    var canSendToGemini: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadAPIKey() {
        apiKey = APIKeyStore.load()
        apiKeySaved = canSendToGemini
        selectedModelName = GeminiModelStore.selectedModelName()
        availableModels = GeminiModelStore.availableModels()
        selectedLanguageIDs = TranscriptionLanguageStore.selectedLanguageIDs()
    }

    func saveAPIKey() {
        do {
            try APIKeyStore.save(apiKey)
            apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            apiKeySaved = canSendToGemini
            errorMessage = nil
            statusMessage = "API キーを保存しました。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        do {
            try APIKeyStore.delete()
            apiKey = ""
            apiKeySaved = false
            statusMessage = "API キーを削除しました。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectModel(_ modelName: String) {
        let normalized = GeminiTranscriptionClient.normalizedModelName(modelName)
        selectedModelName = normalized
        GeminiModelStore.saveSelectedModelName(normalized)
    }

    func refreshModels() {
        guard canSendToGemini else {
            errorMessage = "Gemini API キーが未設定です。"
            return
        }

        isRefreshingModels = true
        errorMessage = nil
        statusMessage = "Gemini モデル一覧を更新しています。"

        Task {
            defer {
                isRefreshingModels = false
            }

            do {
                let client = GeminiTranscriptionClient(apiKey: apiKey, modelName: selectedModelName)
                let models = try await client.listModels()
                availableModels = models
                GeminiModelStore.saveAvailableModels(models)

                if !models.contains(where: { $0.id == selectedModelName }), let firstModel = models.first {
                    selectModel(firstModel.id)
                }

                statusMessage = "Gemini モデル一覧を更新しました。"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Gemini モデル一覧を更新できませんでした。"
            }
        }
    }

    func toggleLanguage(_ language: TranscriptionLanguage) {
        if selectedLanguageIDs.contains(language.id), selectedLanguageIDs.count > 1 {
            selectedLanguageIDs.remove(language.id)
        } else {
            selectedLanguageIDs.insert(language.id)
        }
        TranscriptionLanguageStore.saveSelectedLanguageIDs(selectedLanguageIDs)
    }

    func isLanguageSelected(_ language: TranscriptionLanguage) -> Bool {
        selectedLanguageIDs.contains(language.id)
    }

    var selectedLanguageSummary: String {
        TranscriptionLanguageStore.languages(for: Array(selectedLanguageIDs))
            .map(\.label)
            .joined(separator: "、")
    }

    func toggleRecording(modelContext: ModelContext) {
        if recorder.isRecording {
            stopRecordingAndStartTranscription(modelContext: modelContext)
        } else {
            startRecording()
        }
    }

    func startRecording() {
        Task {
            do {
                _ = try await recorder.startRecording()
                errorMessage = nil
                statusMessage = "録音中です。バックグラウンドでも録音を継続します。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stopRecordingAndStartTranscription(modelContext: ModelContext) {
        do {
            let result = try recorder.stopRecording()
            let record = TranscriptRecord(
                audioFileName: result.url.lastPathComponent,
                duration: result.duration,
                modelName: selectedModelName,
                status: canSendToGemini ? .pendingUpload : .failed,
                errorMessage: canSendToGemini ? nil : "Gemini API キーが未設定です。"
            )
            modelContext.insert(record)
            try modelContext.save()

            if canSendToGemini {
                let job = PendingTranscriptionJob(
                    id: UUID(),
                    recordID: record.id,
                    audioFileName: record.audioFileName,
                    duration: record.duration,
                    modelName: record.modelName,
                    languageIDs: Array(selectedLanguageIDs).sorted(),
                    status: .pendingUpload,
                    uploadedFileURI: nil,
                    updatedAt: Date()
                )
                jobStore.upsert(job)
                process(job: job, record: record, modelContext: modelContext)
            } else {
                statusMessage = "API キーを設定すると録音を送信できます。録音ファイルは履歴に残しました。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry(record: TranscriptRecord, modelContext: ModelContext) {
        guard canSendToGemini else {
            errorMessage = "Gemini API キーが未設定です。"
            return
        }

        let existingJob = jobStore.job(for: record.id)
        let job = existingJob ?? PendingTranscriptionJob(
            id: UUID(),
            recordID: record.id,
            audioFileName: record.audioFileName,
            duration: record.duration,
            modelName: record.modelName,
            languageIDs: Array(selectedLanguageIDs).sorted(),
            status: .pendingUpload,
            uploadedFileURI: nil,
            updatedAt: Date()
        )

        record.status = job.uploadedFileURI == nil ? .pendingUpload : .generating
        record.errorMessage = nil
        try? modelContext.save()
        jobStore.upsert(job)
        process(job: job, record: record, modelContext: modelContext)
    }

    func resumePendingJobs(modelContext: ModelContext) {
        guard canSendToGemini else { return }

        let jobs = jobStore.allJobs()
        guard !jobs.isEmpty else { return }

        let descriptor = FetchDescriptor<TranscriptRecord>()
        guard let records = try? modelContext.fetch(descriptor) else { return }

        for job in jobs {
            guard let record = records.first(where: { $0.id == job.recordID }) else {
                jobStore.remove(recordID: job.recordID)
                continue
            }
            process(job: job, record: record, modelContext: modelContext)
        }
    }

    func delete(record: TranscriptRecord, modelContext: ModelContext) {
        jobStore.remove(recordID: record.id)
        AudioFileStore.deleteRecording(named: record.audioFileName)
        modelContext.delete(record)
        try? modelContext.save()
    }

    private func process(job originalJob: PendingTranscriptionJob, record: TranscriptRecord, modelContext: ModelContext) {
        guard !processingRecordIDs.contains(originalJob.recordID) else { return }
        processingRecordIDs.insert(originalJob.recordID)
        isProcessing = true

        Task {
            defer {
                processingRecordIDs.remove(originalJob.recordID)
                isProcessing = !processingRecordIDs.isEmpty
            }

            var job = originalJob
            let client = GeminiTranscriptionClient(apiKey: apiKey, modelName: job.modelName)

            do {
                let audioURL = AudioFileStore.recordingsDirectory.appendingPathComponent(job.audioFileName)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    throw TranscriptViewModelError.audioFileMissing
                }

                if job.uploadedFileURI == nil {
                    job.status = .uploading
                    job.updatedAt = Date()
                    jobStore.upsert(job)
                    record.status = .uploading
                    record.errorMessage = nil
                    try modelContext.save()
                    statusMessage = "Gemini に音声をアップロードしています。"

                    let uploadedFile = try await client.uploadAudioFile(at: audioURL)
                    job.uploadedFileURI = uploadedFile.uri
                }

                job.status = .generating
                job.updatedAt = Date()
                jobStore.upsert(job)
                record.status = .generating
                record.errorMessage = nil
                try modelContext.save()
                statusMessage = "Gemini で文字起こし中です。"

                guard let uploadedFileURI = job.uploadedFileURI else {
                    throw GeminiError.missingUploadURL
                }

                backgroundTask.begin(named: "Gemini transcription")
                let transcriptLanguages = TranscriptionLanguageStore.languages(for: job.languageIDs)
                let transcript = try await client.generateTranscript(fileURI: uploadedFileURI, languages: transcriptLanguages)
                let currentTitle = record.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let generatedTitle: String?
                if currentTitle.isEmpty {
                    statusMessage = "タイトルを作成しています。"
                    generatedTitle = try? await client.generateTitle(for: transcript)
                } else {
                    generatedTitle = nil
                }
                backgroundTask.end()

                record.transcript = transcript
                if let generatedTitle, currentTitle.isEmpty {
                    record.title = generatedTitle
                }
                record.status = .completed
                record.errorMessage = nil
                try modelContext.save()
                jobStore.remove(recordID: record.id)
                statusMessage = "文字起こしが完了しました。"
                NotificationManager.notifyTranscriptionCompleted()
            } catch {
                backgroundTask.end()
                job.status = record.status.isRunning ? record.status : job.status
                job.updatedAt = Date()
                jobStore.upsert(job)
                record.status = .failed
                record.errorMessage = error.localizedDescription
                try? modelContext.save()
                errorMessage = error.localizedDescription
                statusMessage = "文字起こしに失敗しました。履歴から再試行できます。"
            }
        }
    }
}

enum TranscriptViewModelError: LocalizedError {
    case audioFileMissing

    var errorDescription: String? {
        switch self {
        case .audioFileMissing:
            "録音ファイルが見つかりません。"
        }
    }
}
