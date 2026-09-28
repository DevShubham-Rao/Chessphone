import CoreMotion
import Foundation

/// Detects a shake from the accelerometer, with a cool-down so one shake
/// triggers exactly one callback (the old code fired every 0.1 s while shaking).
final class ShakeDetector {
    var onShake: (() -> Void)?

    private let motion = CMMotionManager()
    private var lastShake = Date.distantPast
    private let threshold = 2.5          // g (gravity alone reads ~1.0)
    private let cooldown: TimeInterval = 1.5

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let d = data else { return }
            let a = d.acceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            guard magnitude > self.threshold else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastShake) > self.cooldown else { return }
            self.lastShake = now
            self.onShake?()
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
    }
}
