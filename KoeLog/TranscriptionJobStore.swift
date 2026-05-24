//
//  TranscriptionJobStore.swift
//  KoeLog
//

import Foundation

@MainActor
final class TranscriptionJobStore {
    static let shared = TranscriptionJobStore()

    private let key = "pending-transcription-jobs"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    func allJobs() -> [PendingTranscriptionJob] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let jobs = try? decoder.decode([PendingTranscriptionJob].self, from: data) else {
            return []
        }
        return jobs.sorted { $0.updatedAt < $1.updatedAt }
    }

    func job(for recordID: UUID) -> PendingTranscriptionJob? {
        allJobs().first { $0.recordID == recordID }
    }

    func upsert(_ job: PendingTranscriptionJob) {
        var jobs = allJobs()
        if let index = jobs.firstIndex(where: { $0.id == job.id || $0.recordID == job.recordID }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        save(jobs)
    }

    func remove(recordID: UUID) {
        save(allJobs().filter { $0.recordID != recordID })
    }

    private func save(_ jobs: [PendingTranscriptionJob]) {
        guard let data = try? encoder.encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
