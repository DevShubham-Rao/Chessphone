import Foundation
import Combine
import ReplayKit
import UIKit

/// iOS replacement for the desktop ffmpeg overlay recorder. Recording is always
/// started by a visible user action and uses ReplayKit's system consent prompt.
@MainActor
final class NativeSessionRecorder: NSObject, ObservableObject, RPScreenRecorderDelegate {
    static let shared = NativeSessionRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Ready to record the app screen."
    @Published private(set) var lastError = ""
    @Published private(set) var latestRecordingURL: URL?

    private let recorder = RPScreenRecorder.shared()
    private var destination: URL?
    private var stopRequested = false
    private var isStopping = false
    private var generation = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private override init() {
        super.init()
        recorder.delegate = self
        // Record app audio only. No room audio or front-camera overlay is requested.
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false
    }

    func startRecording() {
        guard !isBusy, !isRecording else { return }
        lastError = ""
        guard recorder.isAvailable, !recorder.isRecording else {
            lastError = "Screen recording is unavailable. Stop other screen recordings or AirPlay, then try again on a supported iPhone."
            return
        }
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            let folder = documents.appendingPathComponent("ChessPhone Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            destination = folder.appendingPathComponent("ChessPhone-\(stamp)-\(UUID().uuidString.prefix(8)).mp4")
        } catch {
            lastError = "Could not create a recording folder: \(error.localizedDescription)"
            return
        }
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false
        stopRequested = false
        generation += 1
        let requestGeneration = generation
        isBusy = true
        status = "Starting recording; approve the iOS prompt if shown."
        recorder.startRecording { [weak self] error in
            let reason = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == requestGeneration else { return }
                self.isBusy = false
                if let reason {
                    self.destination = nil
                    self.status = "Recording did not start."
                    self.lastError = reason
                    return
                }
                self.isRecording = true
                self.status = "Recording app screen and app audio. Microphone off."
                SessionJournal.shared.record(.info, "Screen recording started; microphone off.")
                // Dismissal/backgrounding may happen while the consent prompt is open.
                if self.stopRequested { self.stopRecording() }
            }
        }
    }

    func stopRecording() {
        if isBusy && !isRecording {
            stopRequested = true
            return
        }
        guard isRecording, !isBusy, let output = destination else { return }
        isBusy = true
        isStopping = true
        status = "Finishing recording…"
        beginFinalizationTime()
        recorder.stopRecording(withOutput: output) { [weak self] error in
            let reason = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.isRecording = false
                self.isStopping = false
                self.destination = nil
                self.stopRequested = false
                self.endFinalizationTime()
                if let reason {
                    self.status = "Recording could not be saved."
                    self.lastError = reason
                    SessionJournal.shared.record(.problem, "Screen recording export failed.", details: ["reason": reason])
                } else if FileManager.default.fileExists(atPath: output.path) {
                    self.latestRecordingURL = output
                    self.status = "Recording saved."
                    SessionJournal.shared.record(.info, "Screen recording saved.", details: ["file": output.lastPathComponent])
                } else {
                    self.status = "Recording could not be saved."
                    self.lastError = "iOS completed recording without creating the movie file."
                }
            }
        }
    }

    /// Finalize when leaving the command center or moving the app to the background.
    func stopIfNeeded() {
        if isRecording || isBusy { stopRecording() }
    }

    nonisolated func screenRecorder(_ screenRecorder: RPScreenRecorder,
                                    didStopRecordingWith previewViewController: RPPreviewViewController?,
                                    error: Error?) {
        let reason = error?.localizedDescription ?? "iOS stopped screen recording before the movie could be exported."
        Task { @MainActor [weak self] in
            guard let self, !self.isStopping, self.isRecording || self.isBusy else { return }
            self.generation += 1
            self.isRecording = false
            self.isBusy = false
            self.destination = nil
            self.stopRequested = false
            self.status = "Recording interrupted."
            self.lastError = reason
            self.endFinalizationTime()
            SessionJournal.shared.record(.problem, "Screen recording interrupted.", details: ["reason": reason])
        }
    }

    private func beginFinalizationTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish ChessPhone recording") { [weak self] in
            Task { @MainActor in self?.endFinalizationTime() }
        }
    }

    private func endFinalizationTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
