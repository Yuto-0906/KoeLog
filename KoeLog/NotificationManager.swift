//
//  NotificationManager.swift
//  KoeLog
//

import Foundation
import UserNotifications

enum NotificationManager {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyTranscriptionCompleted() {
        let content = UNMutableNotificationContent()
        content.title = "文字起こしが完了しました"
        content.body = "KoeLog に戻って結果を確認できます。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "transcription-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
