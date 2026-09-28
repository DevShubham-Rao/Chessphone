import AVFoundation
import UIKit

/// Detects volume up/down button presses by watching the system output
/// volume via KVO and snapping it back to a mid-level after each press,
/// so there's always room to detect the next change in either direction.
///
/// Real device only — the simulator doesn't have real volume hardware.
/// Requires a hidden MPVolumeView to be present in the view hierarchy so
/// iOS lets the app influence system volume at all (see ContentView.swift).
final class VolumeButtonHandler: NSObject {
    static let shared = VolumeButtonHandler()

    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var lastVolume: Float = 0.5
    private var isAdjusting = false

    func start() {
        try? session.setActive(true)
        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        resetVolume()
    }

    func stop() {
        session.removeObserver(self, forKeyPath: "outputVolume")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "outputVolume", !isAdjusting,
              let newVolume = change?[.newKey] as? Float else { return }

        if newVolume > lastVolume {
            onVolumeUp?()
        } else if newVolume < lastVolume {
            onVolumeDown?()
        }
        resetVolume()
    }

    private func resetVolume() {
        isAdjusting = true
        MPVolumeSetter.setVolume(0.5)
        lastVolume = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.isAdjusting = false
        }
    }
}
