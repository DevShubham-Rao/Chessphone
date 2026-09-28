import MediaPlayer
import UIKit

/// Drives the hidden MPVolumeView's slider to programmatically set system
/// volume - the standard (if hacky) trick behind volume-button capture on iOS.
enum MPVolumeSetter {
    static weak var volumeView: MPVolumeView?

    static func setVolume(_ value: Float) {
        let apply = {
            guard let slider = MPVolumeSetter.volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
                print("ChessPhone: hidden volume slider not found; volume buttons can't be captured.")
                return
            }
            slider.value = value
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
