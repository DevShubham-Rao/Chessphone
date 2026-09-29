import AVFoundation
import UIKit

/// Detects volume up/down button presses by watching the system output volume
/// via KVO and snapping it back to a mid-level baseline after each press, so
/// there's always room to detect the next press in either direction.
///
/// Detection is baseline-based: any reading above 0.5 is "up", below 0.5 is
/// "down", and a reading of ~0.5 is our own reset and is ignored. That means
/// rapid presses are all counted (the old version ignored every press that came
/// within 150 ms of the previous one).
///
/// Real device only - the simulator has no volume hardware. Requires the hidden
/// MPVolumeView (see ContentView.swift) so iOS lets the app set system volume.
final class VolumeButtonHandler: NSObject {
    static let shared = VolumeButtonHandler()

    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let baseline: Float = 0.5
    private var isObserving = false
    private var originalVolume: Float?
    private var activeObserver: NSObjectProtocol?

    func start() {
        // Guard against double-start (onAppear can fire more than once), which
        // would register two observers and double-count every press.
        guard !isObserving else { return }

        do {
            // .playback so spoken moves are audible even with the silent switch on;
            // .mixWithOthers so it doesn't stop the user's music.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("ChessPhone: could not activate audio session: \(error)")
        }
        originalVolume = session.outputVolume
        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        isObserving = true

        // After returning from the background the session may need re-activating.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            try? self?.session.setActive(true)
            self?.resetVolume()
        }

        resetVolume()
        // The hidden volume slider can take a moment to exist after launch; try again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resetVolume()
        }
    }

    func stop() {
        // removeObserver without a matching addObserver crashes, so check first.
        guard isObserving else { return }
        session.removeObserver(self, forKeyPath: "outputVolume")
        isObserving = false
        if let token = activeObserver {
            NotificationCenter.default.removeObserver(token)
            activeObserver = nil
        }
        if let original = originalVolume {
            MPVolumeSetter.setVolume(original)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "outputVolume",
              let newVolume = change?[.newKey] as? Float else { return }

        let delta = newVolume - baseline
        // ~0 means this is our own reset back to the baseline (or no real change).
        guard abs(delta) > 0.01 else { return }

        DispatchQueue.main.async { [weak self] in
            if delta > 0 {
                self?.onVolumeUp?()
            } else {
                self?.onVolumeDown?()
            }
        }
        resetVolume()
    }

    private func resetVolume() {
        MPVolumeSetter.setVolume(baseline)
    }
}
