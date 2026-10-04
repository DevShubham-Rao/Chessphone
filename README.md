# ChessPhone + Ray-Ban Meta Board Scan

ChessPhone is an iOS chess assistant that combines:

- Ray-Ban Meta camera capture through Meta Wearables Device Access Toolkit (DAT) 1.0.0
- iPhone camera fallback for testing
- Gemini 3.8 Flash vision parsing
- Stockfish through `chesskit-engine`
- Spoken and/or haptic move output
- Existing manual volume-button move entry, takebacks, saves, skill level, and depth controls

## Vision workflow

When **Board scanning** is enabled and the app is waiting for the opponent's move:

1. Press **Volume Up** on the iPhone.
2. The active image source captures the board.
3. The image is normalized and JPEG-compressed to at most **1024 px on its longest edge**.
4. The JPEG is sent to **`gemini-3.8-flash`** with a strict JSON response schema.
5. The app converts Gemini's camera-relative 8x8 rows into true chess coordinates.
6. The scan is compared with the app's tracked legal position.
   - If exactly one legal opponent move explains the photo, that move is committed normally.
   - If the board is unchanged, the last engine recommendation is replayed.
   - If the board and saved history have drifted apart, the app validates the photographed position, builds a FEN, and asks Stockfish directly without corrupting the saved game.
7. Stockfish returns a UCI move.
8. The existing output settings speak the move, vibrate it, or do both.

## Ray-Ban Meta support

This project uses Meta's current iOS Device Access Toolkit instead of trying to expose the glasses as an `AVCaptureDevice`. The glasses camera is not a normal iOS camera input. Registration, camera permission, device session creation, and photo capture all go through Meta's SDK and Meta AI companion app.

The project is pinned to:

- `meta-wearables-dat-ios` **1.0.0**
- `MWDATCore`
- `MWDATCamera`
- iOS deployment target **17.2**

The camera stream is kept warm at high resolution / 2 FPS so a Volume Up press can request a still without reconnecting first. The low frame rate leaves more transport bandwidth for the photo.

## First-time setup

### 1. Meta glasses

1. Install/update the Meta AI companion app on the iPhone.
2. Pair the Ray-Ban Meta glasses normally.
3. Enable **Developer Mode** for the glasses in Meta AI.
4. Build and run ChessPhone on a real iPhone.
5. Open **Vibration & Audio Settings → Board scanning**.
6. Choose **Ray-Ban Meta glasses**.
7. Tap **Connect Ray-Ban Meta glasses** and approve the registration/permission flow in Meta AI.
8. Turn on **Volume Up scans the board**.

For Developer Mode, `project.yml` uses placeholder Meta app credentials (`MetaAppID` / `ClientToken` = `0`). For a release-channel build, replace these with values from the Wearables Developer Center and build with the correct Apple Development Team.

### 2. Gemini key

The Gemini API key is never hard-coded in source. Supported lookup order:

1. **Keychain**: paste it in Board scanning settings and tap **Save key to Keychain**.
2. **Untracked plist**: copy `Resources/Secrets.example.plist` to `Resources/Secrets.plist` and replace the placeholder.
3. **Xcode environment variable**: set `GEMINI_API_KEY` in the run scheme.

`Resources/Secrets.plist` is gitignored.

For an app distributed to other people, do not ship a reusable Gemini key in the app bundle. Put Gemini behind your own server/proxy and issue short-lived authenticated requests from the app.

### 3. Stockfish NNUE files

Both required network files are already present in `Resources/` in this ZIP:

- `nn-1111cefa1111.nnue`
- `nn-37f18f62d772.nnue`

The app checks for both before declaring Stockfish ready.

## Build

This is an XcodeGen project.

```bash
brew install xcodegen
xcodegen generate
open ChessPhone.xcodeproj
```

For current Meta DAT builds, use a current Xcode toolchain compatible with the SDK. Run on a real iPhone for Ray-Ban Meta and volume-button testing.

The included Builder/GitHub workflow can also generate the Xcode project before building.

## Important iPhone Volume Up behavior

Apple does not expose a dedicated public "hardware Volume Up button pressed" callback. This app observes `AVAudioSession.outputVolume` and embeds an `MPVolumeView`, then restores the volume to a midpoint after a press. This works only on a real device and is intentionally isolated in `VolumeButtonHandler.swift` / `MPVolumeSetter.swift`.

Because it is volume-state observation rather than a formal button-event API, test this on every iOS version you plan to use. If you later want a glasses-native trigger, Meta DAT 1.0 also introduced an experimental Inputs module, but this project does not require that experimental capability.

## Main vision files

- `ChessPhone/GlassesCameraSource.swift`: Meta registration/session/camera/photo capture
- `ChessPhone/BoardImageSource.swift`: image-source protocol + iPhone fallback
- `ChessPhone/ImagePreprocessor.swift`: 1024 px JPEG normalization
- `ChessPhone/GeminiKeyProvider.swift`: Keychain/plist/environment key loading
- `ChessPhone/GeminiBoardReader.swift`: Gemini 3.8 Flash structured vision request
- `ChessPhone/BoardPosition.swift`: orientation, sanity checks, scan-to-move matching, FEN-ready position
- `ChessPhone/VisionCoordinator.swift`: capture → compress → Gemini orchestration + settings UI
- `ChessPhone/GameState.swift`: Volume Up trigger and scan → Stockfish integration

## Testing status

Performed in this package:

- Swift parser check over every `.swift` source file
- `project.yml` YAML validation
- Compiled pure-Swift tests for White camera orientation, Black camera orientation, legal scan matching (`e2e4`), and rebuilding a scanned position
- Verified both Stockfish NNUE files are present and non-empty

Still requires a real Apple/Meta environment:

- Xcode compile/link against the Meta binary SDK
- Meta AI registration callback
- Ray-Ban Meta physical capture
- iPhone hardware Volume Up behavior
- Real Gemini API request with your key

Those cannot be truthfully hardware-verified from a Linux build container.
