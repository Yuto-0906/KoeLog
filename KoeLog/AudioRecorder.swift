//
//  AudioRecorder.swift
//  KoeLog
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?

    func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                Task { @MainActor in
                    self.permissionDenied = !granted
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func startRecording() async throws -> URL {
        guard await requestPermission() else {
            throw AudioRecorderError.permissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = AudioFileStore.newRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw AudioRecorderError.startFailed
        }

        self.recorder = recorder
        startedAt = Date()
        elapsedTime = 0
        isRecording = true
        startTimer()
        return url
    }

    func stopRecording() throws -> RecordingResult {
        guard let recorder else {
            throw AudioRecorderError.notRecording
        }

        let url = recorder.url
        let duration = currentElapsedTime()
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        stopTimer()

        self.recorder = nil
        startedAt = nil
        elapsedTime = 0
        isRecording = false

        return RecordingResult(url: url, duration: max(duration, 0))
    }

    func currentElapsedTime(at date: Date = Date()) -> TimeInterval {
        if isRecording, let startedAt {
            return date.timeIntervalSince(startedAt)
        }
        return elapsedTime
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.elapsedTime = self.currentElapsedTime()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct RecordingResult {
    var url: URL
    var duration: TimeInterval
}

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case startFailed
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "マイクの使用が許可されていません。設定アプリで許可してください。"
        case .startFailed:
            "録音を開始できませんでした。"
        case .notRecording:
            "録音中ではありません。"
        }
    }
}
