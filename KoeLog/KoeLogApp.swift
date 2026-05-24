//
//  KoeLogApp.swift
//  KoeLog
//
//  Created by 源間悠翔 on 2026/05/24.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct KoeLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: TranscriptRecord.self)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        GeminiBackgroundSessionDelegate.shared.setBackgroundCompletionHandler(completionHandler)
    }
}
