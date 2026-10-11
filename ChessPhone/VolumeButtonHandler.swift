import AVFoundation
import UIKit

/// Best-effort foreground hardware input through public outputVolume KVO.
/// Compare actual consecutive values rather than assuming every reset worked.
/// Only a pending reset's target is suppressed, not rapid user presses.
final class VolumeButtonHandler: NSObject {
    static let shared = VolumeButtonHandler()
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let baseline: Float = 0.5
    private var observation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var originalVolume: Float?
    private var pendingReset = false
    private var resetGeneration = 0
    private var recoveryGeneration = 0
    private var acceptingInput = false
    private var interrupted = false

    func start() {
        guard observation == nil else { reconnect(); return }
        originalVolume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue else { return }
            DispatchQueue.main.async { [weak self] in self?.volumeChanged(from: old, to: new) }
        }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.interrupted = false
            self?.reconnect()
        }
        observe(UIApplication.willResignActiveNotification) { [weak self] _ in
            self?.acceptingInput = false
            self?.recoveryGeneration += 1
        }
        observe(AVAudioSession.interruptionNotification) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self.interrupted = type == .began
            if self.interrupted {
                self.acceptingInput = false
                self.recoveryGeneration += 1
            } else { self.reconnect() }
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason != .categoryChange else { return }
            self?.reconnect()
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.interrupted = false
            self?.reconnect()
        }
        reconnect()
    }

    /// Retry after the volume view is mounted or an audio route/session changes.
    func reconnect() {
        guard observation != nil, !interrupted,
              UIApplication.shared.applicationState == .active else { return }
        acceptingInput = false
        recoveryGeneration += 1
        let generation = recoveryGeneration
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("ChessPhone: audio-session recovery failed: \(error)")
            return
        }
        for delay in [0.0, 0.2, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.observation != nil,
                      self.recoveryGeneration == generation, !self.interrupted,
                      UIApplication.shared.applicationState == .active else { return }
                // Only repeat while recovering, never reset an in-progress tap.
                guard !self.acceptingInput else { return }
                self.resetVolume()
                let reset = self.resetGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self, self.recoveryGeneration == generation,
                          self.resetGeneration == reset, self.observation != nil,
                          !self.interrupted,
                          UIApplication.shared.applicationState == .active else { return }
                    if abs(self.session.outputVolume - self.baseline) < 0.01 {
                        self.acceptingInput = true
                    } else if delay == 0.6 {
                        // A rejected slider reset must not disable all input.
                        self.acceptingInput = true
                    }
                }
            }
        }
    }

    func stop() {
        guard observation != nil else { return }
        acceptingInput = false
        recoveryGeneration += 1
        resetGeneration += 1
        pendingReset = false
        observation?.invalidate()
        observation = nil
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
        if let originalVolume { MPVolumeSetter.setVolume(originalVolume) }
        originalVolume = nil
    }

    private func observe(_ name: Notification.Name, action: @escaping (Notification) -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil,
                                                              queue: .main, using: action))
    }

    private func volumeChanged(from old: Float, to new: Float) {
        guard observation != nil else { return }
        if pendingReset, abs(new - baseline) < 0.01 {
            pendingReset = false
            return
        }
        guard acceptingInput, !interrupted,
              UIApplication.shared.applicationState == .active,
              abs(new - old) > 0.001 else { return }
        if new > old { onVolumeUp?() } else { onVolumeDown?() }
        resetVolume()
    }

    private func resetVolume() {
        guard observation != nil else { return }
        guard abs(session.outputVolume - baseline) > 0.001 else { return }
        resetGeneration += 1
        let generation = resetGeneration
        pendingReset = true
        if !MPVolumeSetter.setVolume(baseline) { pendingReset = false }
        // Do not leave stale suppression state if iOS ignores a slider write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.resetGeneration == generation else { return }
            self.pendingReset = false
        }
    }
}
