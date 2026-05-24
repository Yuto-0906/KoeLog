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
    private let modelContainer: ModelContainer = {
        let schema = Schema([TranscriptRecord.self])
        let configuration = ModelConfiguration(
            "KoeLog",
            schema: schema,
            cloudKitDatabase: .private("iCloud.com.YG.KoeLog")
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
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
