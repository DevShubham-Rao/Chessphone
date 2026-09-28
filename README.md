# ChessPhone

iPhone chess app, screen-minimal: volume buttons and shake for input,
haptics for output, real Stockfish (via chesskit-engine) for moves.

## Controls
- Volume UP: increment the tap counter (1, 2, 3...)
- Volume DOWN: confirm current count, advance to next input phase
- Shake: repeat the last haptic output

## One-time setup: Stockfish's neural network files
Stockfish needs two ".nnue" files to run and they're too big to ship
in this ZIP or commit conveniently, so grab them yourself once:

1. Download these two files (click through, they're official Stockfish
   test-server files):
   - Big net: https://tests.stockfishchess.org/nns?network_name=1111cefa1111&user=
   - Small net: https://tests.stockfishchess.org/nns?network_name=37f18f62d772&user=
2. Rename them EXACTLY to:
   - nn-1111cefa1111.nnue
   - nn-37f18f62d772.nnue
3. Put both in this project's Resources/ folder (next to this README).

They're gitignored on purpose (they're large binaries), but that's
fine: `builder ios build` pushes your whole working tree, gitignore
rules aside -- so as long as they're sitting in Resources/ on your
machine when you run the build, they'll be included and bundled into
the app. If you ever build on a different machine, redo steps 1-3
there too.

## Known unconfirmed bits (check if the build errors here)
Two calls in EngineManager.swift are written against chesskit-engine's
documented usage examples but weren't independently verified against
its exact source:
- `move.bestMove` in the `.bestmove` response case -- if this doesn't
  compile, use Xcode's autocomplete on `move` to find the real
  property name for the move string.
- `.position(.startpos, moves: moves)` -- if this variant doesn't
  exist, build a FEN string after each move instead and call
  `.position(.fen(fen))`, which the library's README confirms exists.

## What's still not implemented
- Move legality / board-state validation. The app sends whatever
  4-character move your taps produce straight to Stockfish; it
  doesn't check it's a real legal move first. Stockfish will likely
  just ignore or misbehave on an illegal move rather than crash, but
  this isn't handled gracefully yet.
- Game-over detection (checkmate, stalemate, draws).
- Any visual board -- this stays screen-minimal by design, but there's
  no way to double check the position visually if something goes wrong.

## Building & installing
Not a Builder project on its own (no builder.json) unless you've
already run `builder init` in this folder -- see prior setup:
  builder auth github
  builder init
  builder signing setup --distribution development --devices-from-mobai
  builder ios build --profile development --distribute
Or use the included plain GitHub Actions workflow for an unsigned
build to confirm it compiles (won't have the NNUE files unless you
commit them there instead -- see workflow file).
