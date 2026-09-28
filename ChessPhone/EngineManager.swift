import Foundation
import ChessKitEngine

/// Wraps chesskit-engine's Stockfish for this app: starts it once,
/// loads the bundled NNUE network files, and exposes a simple
/// async "give me a move" call.
///
/// Two spots below are marked NOTE — they're written against the
/// library's documented usage examples, but the exact property/case
/// shape wasn't independently confirmed against the source. If Xcode
/// flags either, autocomplete on the type will show the real shape;
/// it's a small fix either way.
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

        engine.start()

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
        case let .bestmove(move):
            // NOTE: written assuming a `.bestMove` string property on the
            // associated value, per the library's UCI "bestmove <move>"
            // output. Check autocomplete here if this doesn't compile.
            pendingContinuation?.resume(returning: move.bestMove)
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
