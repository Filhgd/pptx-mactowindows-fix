import Foundation
import SwiftUI

/// One presentation handled by the app, as shown in the window's list.
struct Job: Identifiable, Equatable {
    enum Source: Equatable { case manual, watched }
    enum State: Equatable {
        case queued
        case working
        case done(images: Int)
        case nothing
        case failed(String)
    }

    let id = UUID()
    let input: URL
    let output: URL
    let source: Source
    var state: State
}

struct BatchProgress: Equatable {
    var total: Int
    var finished: Int
    var current: String
}

/// Everything the window shows. Changed on the main thread only.
final class AppModel: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var batch: BatchProgress?
    @Published var watchFolder: URL?
    @Published var openAtLogin = false
    @Published var update: ReleaseInfo?
    @Published var dropMessage: String?
    @Published var showOnboarding = false
    @Published var dropTargeted = false

    // Actions, provided by the app delegate.
    var onDrop: ([URL]) -> Void = { _ in }
    var onChooseFiles: () -> Void = {}
    var onChooseFolder: () -> Void = {}
    var onStopWatching: () -> Void = {}
    var onSetOpenAtLogin: (Bool) -> Void = { _ in }
    var onShowUpdate: () -> Void = {}
    var onDownloadUpdate: () -> Void = {}
    var onFinishOnboarding: (Bool) -> Void = { _ in }

    private var messageTimer: Timer?

    var version: String { Updater.currentVersion }

    func flash(_ message: String) {
        dropMessage = message
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            withAnimation { self?.dropMessage = nil }
        }
    }

    /// Adds jobs at the top of the list (keeps the list short).
    func add(_ new: [Job]) {
        jobs.insert(contentsOf: new, at: 0)
        if jobs.count > 100 { jobs.removeLast(jobs.count - 100) }
    }

    func setState(_ id: UUID, _ state: Job.State) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = state }
    }

    func clearFinished() {
        jobs.removeAll { job in
            switch job.state {
            case .queued, .working: return false
            default: return true
            }
        }
    }
}
