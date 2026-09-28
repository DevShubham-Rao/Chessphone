# ChessPhone

iPhone chess app, screen-minimal: volume buttons and shake replace
the watch's Digital Crown from the earlier watchOS version.

## Controls
- Volume UP: increment the tap counter (1, 2, 3...)
- Volume DOWN: confirm current count, advance to next input phase
  (source column -> source row -> target column -> target row -> submit)
- Shake: repeat the last haptic output (engine's move)

## Important limitation
iOS has no public API to detect volume up + down pressed at once, so
"both = repeat" from the original ask isn't technically possible.
Shake is the substitute here. Volume-button capture itself is a real
device only feature (KVO on AVAudioSession.outputVolume + a hidden
MPVolumeView) — it won't work in the simulator, and it may briefly
flash the system volume HUD despite the volume-snapback trick.

## What's stubbed
- StubEngine.swift returns a fixed reply move. Swap in a real chess
  engine (Stockfish via a C++ bridge, or a Swift chess library) later.
- No board/legality tracking; currentFEN is a placeholder.

## Building & installing
This repo is NOT a Builder project (no builder.json) — don't run
`builder init` here, or point Builder at this repo separately if you
want its signing/distribute flow:
  builder auth github
  builder init            # run FROM this repo's folder
  builder signing setup --distribution development --devices-from-mobai
  builder ios build --profile development --distribute
Or just use the plain GitHub Actions workflow included here for an
unsigned build to confirm it compiles.
