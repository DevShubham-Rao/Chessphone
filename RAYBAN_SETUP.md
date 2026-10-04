# Ray-Ban Meta Integration Architecture

## Runtime path

`iPhone Volume Up`
→ `VolumeButtonHandler`
→ `ChessPhoneViewModel.requestBoardScan()`
→ `VisionCoordinator`
→ `GlassesCameraSource` (Meta DAT) or `PhoneCameraSource`
→ `ImagePreprocessor` (max 1024 px, JPEG)
→ `GeminiBoardReader` (`gemini-3.8-flash`, structured JSON)
→ `BoardOrienter` / `ScanMatcher`
→ legal `Position.fen`
→ `EngineManager` / Stockfish
→ `SpeechEngine` and/or `HapticEngine`

## Why Meta DAT is required

Ray-Ban Meta is not exposed to third-party iOS apps as an `AVCaptureDevice`. Use `MWDATCore` for registration, permission, and device sessions, and `MWDATCamera` for the camera stream/photo capture.

The app initializes Meta DAT at launch, handles the `metaWearablesAction` URL callback, requests camera permission through Meta AI, starts a `DeviceSession`, attaches a `Camera`, keeps its `Stream` warm, and calls `capturePhoto(format: .jpeg)` when the trigger fires.

## Gemini response format

Gemini is asked to return only a structured board observation:

- `boardVisible: Bool`
- `rows: [String]` with exactly 8 camera-relative rows
- chess piece letters (`PNBRQK` / lowercase) and `.` for empty
- `confidence: high | medium | low`
- optional notes

The model is not trusted to decide chess legality. The app performs orientation and legality checks locally before Stockfish sees a position.

## Position safety

A physical photo cannot reveal historical state such as whether a king/rook previously moved or whether en passant is currently available. The app therefore:

- preserves castling rights only when the tracked game still allows them and the needed king/rook are physically present
- omits en passant in scan-recovery mode
- requires exactly one king per side
- rejects impossible pawn counts / pawns on the first or eighth rank
- rejects a position where the side that just moved is still in check

When the scan exactly matches one legal opponent move from the tracked game, the full tracked history is preserved and these approximations are unnecessary.
