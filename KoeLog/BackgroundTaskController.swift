//
//  BackgroundTaskController.swift
//  KoeLog
//

import UIKit

@MainActor
final class BackgroundTaskController {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(named name: String) {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
