import MediaPlayer
import UIKit

/// Uses the mounted MPVolumeView control rather than a detached slider.
enum MPVolumeSetter {
    private final class WeakView {
        weak var view: MPVolumeView?
        init(_ view: MPVolumeView) { self.view = view }
    }
    private static var views: [WeakView] = []
    static var volumeView: MPVolumeView? {
        get { views.reversed().compactMap { $0.view }.first { $0.window != nil } }
        set {
            views.removeAll { $0.view == nil || $0.view === newValue }
            if let newValue { views.append(WeakView(newValue)) }
        }
    }

    @discardableResult
    static func setVolume(_ value: Float) -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { setVolume(value) }
            return false
        }
        guard let view = volumeView, view.window != nil,
              let slider = view.subviews.compactMap({ $0 as? UISlider }).first else {
            return false
        }
        slider.setValue(min(max(value, 0), 1), animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        return true
    }
}
