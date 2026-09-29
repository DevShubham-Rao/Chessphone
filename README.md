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

## How it plays
- Pick WHITE or BLACK. The engine always advises YOU; you only type in your opponent's moves.
  - White: the engine recommends your first move right away (haptics + text). You play it on
    your real board, then enter your opponent's reply.
  - Black: nothing is played automatically. Enter White's first move, then the engine
    recommends your reply.
- Enter the opponent's move as four numbers: FROM column, FROM row, TO column, TO row.
  Columns 1-8 = a-h, rows 1-8. These are always real board coordinates
  (a1 = 1,1; h8 = 8,8) whichever side you play; only the on-screen board flips.
- Volume UP counts taps, Volume DOWN confirms the number and moves to the next step.
  Confirming with 0 taps cancels the move you're entering. Max 8 taps (4 for promotion).
- Pawn promotion asks for a fifth number: 1=Queen 2=Rook 3=Bishop 4=Knight.
- The engine's move is played back as haptics: from-col pulses, from-row pulses,
  a success buzz, to-col pulses, to-row pulses (+ heavy pulses for promotion,
  + two warning buzzes for check, + three heavy thumps for game over).
  Shake repeats the last recommended move.

## Safety checks
- The app has its own rules engine (ChessRules.swift). Your move is checked twice:
  once when you finish entering it, and again inside `ChessGame.play()`, which
  regenerates the legal moves and verifies your king isn't left in check.
- The engine's reply is also verified against those legal moves before it is played.
- Stockfish always receives the app's exact position as a FEN, so the two can't
  drift out of sync.
- At launch the app runs a test search; if Stockfish can't answer, the screen says
  so (usually: NNUE files missing) instead of quietly playing a made-up move.

## What's still not implemented
- Undo / takebacks.
- Skill levels (the engine always searches to depth 12).
- Saving a game in progress.

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
