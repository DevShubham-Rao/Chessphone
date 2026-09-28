import MediaPlayer

/// Drives the hidden MPVolumeView's slider to programmatically set
/// system volume — this is the standard (if hacky) trick behind
/// volume-button capture on iOS.
enum MPVolumeSetter {
    static weak var volumeView: MPVolumeView?

    static func setVolume(_ value: Float) {
        guard let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        DispatchQueue.main.async {
            slider.value = value
        }
    }
}
