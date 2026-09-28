import Foundation

/// Placeholder for a real chess engine. Returns a fixed reply so the
/// input -> haptic pipeline is testable without Stockfish wired in yet.
enum StubEngine {
    static func bestMove(forFEN fen: String) -> String {
        return "e7e5"
    }
}
