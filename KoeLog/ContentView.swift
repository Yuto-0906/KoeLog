//
//  ContentView.swift
//  KoeLog
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = TranscriptViewModel()
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]

    var body: some View {
        NavigationStack {
            List {
                Section("Gemini API キー") {
                    SecureField("API キー", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button("保存") {
                            viewModel.saveAPIKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("削除") {
                            viewModel.deleteAPIKey()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.apiKeySaved)

                        Spacer()

                        Label(viewModel.apiKeySaved ? "設定済み" : "未設定", systemImage: viewModel.apiKeySaved ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(viewModel.apiKeySaved ? .green : .orange)
                    }
                }

                Section("録音") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.recorder.isRecording ? "録音中" : "待機中")
                                    .font(.headline)
                                Text(formatDuration(viewModel.recorder.elapsedTime))
                                    .font(.title2.monospacedDigit())
                            }

                            Spacer()

                            Button {
                                viewModel.toggleRecording(modelContext: modelContext)
                            } label: {
                                Label(
                                    viewModel.recorder.isRecording ? "停止" : "録音",
                                    systemImage: viewModel.recorder.isRecording ? "stop.fill" : "record.circle"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(viewModel.recorder.isRecording ? .red : .blue)
                        }

                        Text(viewModel.statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section("エラー") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("履歴") {
                    if records.isEmpty {
                        ContentUnavailableView("履歴がありません", systemImage: "waveform", description: Text("録音を停止すると履歴に保存されます。"))
                    } else {
                        ForEach(records) { record in
                            NavigationLink {
                                TranscriptDetailView(record: record, viewModel: viewModel)
                            } label: {
                                TranscriptRow(record: record)
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { records[$0] }.forEach { record in
                                viewModel.delete(record: record, modelContext: modelContext)
                            }
                        }
                    }
                }
            }
            .navigationTitle("KoeLog")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !records.isEmpty {
                        EditButton()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.isProcessing {
                        ProgressView()
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadAPIKey()
            NotificationManager.requestAuthorization()
            viewModel.resumePendingJobs(modelContext: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.loadAPIKey()
                viewModel.resumePendingJobs(modelContext: modelContext)
            }
        }
    }
}

struct TranscriptRow: View {
    let record: TranscriptRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.headline)
                Spacer()
                StatusBadge(status: record.status)
            }

            Text(rowSummary)
                .lineLimit(2)
                .foregroundStyle(record.transcript.isEmpty ? .secondary : .primary)

            HStack(spacing: 12) {
                Label(formatDuration(record.duration), systemImage: "clock")
                Label(record.modelName, systemImage: "sparkles")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var rowSummary: String {
        if !record.transcript.isEmpty {
            record.transcript
        } else if let errorMessage = record.errorMessage {
            errorMessage
        } else {
            record.status.label
        }
    }
}

struct TranscriptDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var record: TranscriptRecord
    @ObservedObject var viewModel: TranscriptViewModel
    @StateObject private var player = AudioPlayer()
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        List {
            Section("状態") {
                LabeledContent("作成日時", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("録音時間", value: formatDuration(record.duration))
                LabeledContent("モデル", value: record.modelName)
                HStack {
                    Text("解析状態")
                    Spacer()
                    StatusBadge(status: record.status)
                }

                if let errorMessage = record.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("録音") {
                Button {
                    player.toggle(url: record.audioURL)
                } label: {
                    Label(player.isPlaying ? "停止" : "再生", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(!FileManager.default.fileExists(atPath: record.audioURL.path))
            }

            Section("文字起こし") {
                if record.transcript.isEmpty {
                    Text(record.status == .failed ? "文字起こし結果はありません。" : "解析中です。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(record.transcript)
                        .textSelection(.enabled)
                }
            }

            if record.status != .completed {
                Section {
                    Button {
                        viewModel.retry(record: record, modelContext: modelContext)
                    } label: {
                        Label("再試行", systemImage: "arrow.clockwise")
                    }
                    .disabled(!viewModel.canSendToGemini)
                }
            }
        }
        .navigationTitle("履歴詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("この履歴を削除しますか？", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("履歴と録音を削除", role: .destructive) {
                player.stop()
                viewModel.delete(record: record, modelContext: modelContext)
                dismiss()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("文字起こし履歴と録音ファイルを削除します。")
        }
    }
}

struct StatusBadge: View {
    let status: TranscriptionStatus

    var body: some View {
        Text(status.label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundStyle, in: Capsule())
            .foregroundStyle(foregroundStyle)
    }

    private var backgroundStyle: Color {
        switch status {
        case .completed:
            .green.opacity(0.15)
        case .failed:
            .red.opacity(0.15)
        case .pendingUpload, .uploading, .generating:
            .blue.opacity(0.15)
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .completed:
            .green
        case .failed:
            .red
        case .pendingUpload, .uploading, .generating:
            .blue
        }
    }
}

func formatDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(Int(duration.rounded()), 0)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
}

#Preview {
    ContentView()
        .modelContainer(for: TranscriptRecord.self, inMemory: true)
}
