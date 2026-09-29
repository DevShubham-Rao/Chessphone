import AVFoundation

/// Speaks moves out loud. Settings are saved automatically and are editable in Vibration Settings.
@MainActor
final class SpeechEngine: ObservableObject {
    static let shared = SpeechEngine()

    enum Timing: String, CaseIterable, Identifiable {
        case together, afterVibration, audioOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .together: return "Same time as vibration"
            case .afterVibration: return "After the vibration"
            case .audioOnly: return "Audio only (no vibration)"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case letters, numbers
        var id: String { rawValue }
        var title: String {
            switch self {
            case .letters: return "Squares (\"ay two to ay four\")"
            case .numbers: return "Tap numbers (\"one, two to one, four\")"
            }
        }
    }

    @Published var enabled: Bool { didSet { save() } }
    @Published var timing: Timing { didSet { save() } }
    @Published var style: Style { didSet { save() } }
    @Published var includePieceName: Bool { didSet { save() } }
    /// AVSpeechUtterance rate, 0...1 (0.5 is the system default).
    @Published var rate: Double { didSet { save() } }
    /// Relative to the phone's volume, 0...1.
    @Published var volume: Double { didSet { save() } }

    private let synthesizer = AVSpeechSynthesizer()

    private let letterWords = ["ay", "bee", "see", "dee", "ee", "eff", "gee", "aitch"]
    private let numberWords = ["one", "two", "three", "four", "five", "six", "seven", "eight"]

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "speechEnabled") as? Bool ?? true
        timing = Timing(rawValue: d.string(forKey: "speechTiming") ?? "") ?? .together
        style = Style(rawValue: d.string(forKey: "speechStyle") ?? "") ?? .letters
        includePieceName = d.object(forKey: "speechPieceName") as? Bool ?? true
        rate = d.object(forKey: "speechRate") as? Double ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        volume = d.object(forKey: "speechVolume") as? Double ?? 1.0
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "speechEnabled")
        d.set(timing.rawValue, forKey: "speechTiming")
        d.set(style.rawValue, forKey: "speechStyle")
        d.set(includePieceName, forKey: "speechPieceName")
        d.set(rate, forKey: "speechRate")
        d.set(volume, forKey: "speechVolume")
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(min(max(rate, 0.1), 0.9))
        utterance.volume = Float(min(max(volume, 0.0), 1.0))
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speakSample() {
        speak("Knight, gee one to eff three")
    }

    // MARK: - Wording

    /// e.g. "Knight, gee one to eff three" / "Pawn, ee two to ee four, check".
    func phrase(for move: Move, piece: PieceType?, captured: PieceType?,
                suffix: HapticEngine.Suffix = .none, outcome: GameOutcome? = nil) -> String {
        var text = ""

        if let piece = piece, piece == .king,
           abs(Square.file(move.to) - Square.file(move.from)) == 2 {
            text += Square.file(move.to) > Square.file(move.from) ? "Castles kingside. " : "Castles queenside. "
        }
        if includePieceName, let piece = piece {
            text += pieceName(piece) + ", "
        }
        text += "\(spokenSquare(move.from)) to \(spokenSquare(move.to))"
        if let captured = captured {
            text += ", capturing \(pieceName(captured))"
        }
        if let promotion = move.promotion {
            text += ", promotes to \(pieceName(promotion))"
        }
        switch suffix {
        case .none: break
        case .check: text += ", check"
        case .gameOver:
            if let outcome = outcome { text += ". " + outcome.summary }
        }
        return text
    }

    private func spokenSquare(_ square: Int) -> String {
        let file = Square.file(square)
        let rank = Square.rank(square)
        switch style {
        case .letters: return "\(letterWords[file]) \(numberWords[rank])"
        case .numbers: return "\(numberWords[file]), \(numberWords[rank])"
        }
    }

    private func pieceName(_ type: PieceType) -> String {
        switch type {
        case .pawn: return "pawn"
        case .knight: return "knight"
        case .bishop: return "bishop"
        case .rook: return "rook"
        case .queen: return "queen"
        case .king: return "king"
        }
    }
}
