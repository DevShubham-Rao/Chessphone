import Foundation
import ChessKitEngine

/// Wraps chesskit-engine's Stockfish for this app: starts it once,
/// loads the bundled NNUE network files, and exposes a simple
/// async "give me a move" call.
///
/// The `.bestmove` case shape and `.start()` being async were confirmed
/// against a real build log. One spot below is still marked NOTE — the
/// `.position(.startpos, moves:)` call is written against standard UCI
/// but wasn't independently confirmed against this library's source.
@MainActor
final class EngineManager {
    static let shared = EngineManager()

    private var engine: Engine?
    private var started = false
    private var pendingContinuation: CheckedContinuation<String?, Never>?

    func start() async {
        guard !started else { return }
        started = true

        let engine = Engine(type: .stockfish)
        self.engine = engine

        guard
            let bigNet = Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue"),
            let smallNet = Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue")
        else {
            print("ChessPhone: NNUE files missing from the app bundle — see README. Engine will not run.")
            return
        }

        await engine.start()

        Task {
            for await response in await engine.responseStream! {
                await self.handle(response)
            }
        }

        await engine.send(command: .setoption(id: "EvalFile", value: bigNet.path))
        await engine.send(command: .setoption(id: "EvalFileSmall", value: smallNet.path))
    }

    private func handle(_ response: EngineResponse) async {
        switch response {
        case .bestmove(move: let move, ponder: _):
            pendingContinuation?.resume(returning: move)
            pendingContinuation = nil
        default:
            break
        }
    }

    /// Sends the full move history (UCI long algebraic, e.g. "e2e4")
    /// from the starting position and returns Stockfish's reply.
    func bestMove(forMoveHistory moves: [String], depth: Int = 12) async -> String? {
        guard let engine, await engine.isRunning else { return nil }

        await engine.send(command: .stop)
        // NOTE: `.position(.startpos, moves:)` matches standard UCI
        // ("position startpos moves e2e4 e7e5 ..."), but the README only
        // explicitly demos `.startpos` and `.fen(_:)` alone. If this
        // exact call doesn't compile, build a FEN string after each move
        // instead and use `.position(.fen(fen))`, which IS confirmed.
        await engine.send(command: .position(.startpos, moves: moves))
        await engine.send(command: .go(depth: depth))

        return await withCheckedContinuation { continuation in
            self.pendingContinuation = continuation
        }
    }
}
