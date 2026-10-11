import SwiftUI

struct SavedHapticPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var pattern: HapticPattern
}

@MainActor
final class FeedbackSettings: ObservableObject {
    static let shared = FeedbackSettings()
    @Published var allOff = false { didSet { save() } }
    @Published var movesEnabled = true { didSet { save() } }
    @Published var buttonsEnabled = true { didSet { save() } }
    @Published var errorsEnabled = true { didSet { save() } }
    @Published var errorDuration = 0.3 { didSet { save() } }
    @Published var errorIntensity = 1.0 { didSet { save() } }
    @Published var errorCount = 2 { didSet { save() } }
    @Published var errorGap = 0.2 { didSet { save() } }
    @Published var speakErrors = false { didSet { save() } }
    @Published var presets: [SavedHapticPreset] = [] { didSet { save() } }

    private struct Stored: Codable {
        var allOff: Bool
        var movesEnabled: Bool
        var buttonsEnabled: Bool
        var errorsEnabled: Bool
        var errorDuration: Double
        var errorIntensity: Double
        var errorCount: Int
        var errorGap: Double
        var speakErrors: Bool
        var presets: [SavedHapticPreset]
    }
    private let key = "ChessPhone.feedbackSettingsV1"
    private init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        allOff = s.allOff
        movesEnabled = s.movesEnabled
        buttonsEnabled = s.buttonsEnabled
        errorsEnabled = s.errorsEnabled
        errorDuration = min(max(s.errorDuration, 0.05), 3)
        errorIntensity = min(max(s.errorIntensity, 0.1), 1)
        errorCount = min(max(s.errorCount, 1), 8)
        errorGap = min(max(s.errorGap, 0), 3)
        speakErrors = s.speakErrors
        presets = s.presets
    }
    private func save() {
        let s = Stored(allOff: allOff, movesEnabled: movesEnabled,
                       buttonsEnabled: buttonsEnabled, errorsEnabled: errorsEnabled,
                       errorDuration: errorDuration, errorIntensity: errorIntensity,
                       errorCount: errorCount, errorGap: errorGap,
                       speakErrors: speakErrors, presets: presets)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }
}
