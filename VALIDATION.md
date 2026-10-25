# Validation — 2026-10-25

## Checks completed in the Windows workspace

- Parsed **39 Swift files**, including application code and tests, with tree-sitter 0.26.0 and tree-sitter-swift 0.7.4: **zero syntax findings**.
- Parsed **5 YAML files** (project plus four workflows), rejecting duplicate mapping keys.
- Checked that the explicit `ChessPhone` Xcode scheme references `ChessPhoneTests`, that all source directories exist, and that ChessKitEngine is pinned to 0.7.0.
- Confirmed that both NNUE resources are present and byte-for-byte identical to the original uploaded ZIP.
- Confirmed that `Resources/Secrets.plist` is absent; scanned source/configuration/documentation for common embedded API-key and private-key patterns: zero findings.
- Reviewed cancellation and generation guards for pause, undo, new game, manual scans, live reads, engine restarts, and old-session retries.

These are syntax, configuration, resource, and source-review checks. They do not establish successful Swift type-checking, compilation, linking, or device behavior.

## Included tests

The `ChessPhoneTests` target contains **32 XCTest methods**:

| Test file | Cases | Coverage |
| --- | ---: | --- |
| ChessNotationTests.swift | 10 | Valid/invalid FEN, SAN/UCI, disambiguation, castling, en passant, promotion, checkmate PGN, custom start and numbering, repetition. |
| BoardScanTests.swift | 5 | Absolute coordinates, blocked/low-confidence/malformed boards, exact legal successors, unchanged position. |
| EngineEvaluationTests.swift | 7 | Actual SDK score serialization, centipawns, mate, asking-side sign, bounds/secondary lines, malformed responses, evaluation range. |
| VisionBudgetTests.swift | 5 | Boundary reservation, resume without resetting history, retry allowance, session resets, invalid numeric settings. |
| SessionJournalTests.swift | 5 | 300-event memory vs complete file history, append-only resume, snapshot non-persistence, PGN updates, opt-in frames and secret redaction. |

**The XCTest suite was not executed here.** The bundled `.github/workflows/ios-validation.yml` builds and runs it on an available iPhone simulator when the project is pushed to a repository with Actions enabled. That workflow was created but was not dispatched from this workspace.

## Required build/device checks

Use Xcode 26+ / Swift 6.2+ to generate, compile, link, and run the tests. On a real iPhone, verify Meta registration and camera streaming, iPhone still capture, Gemini calls using your own key, hardware volume events, haptics, speech/audio routes, foreground/background transitions, and ReplayKit movie export. Actual provider billing must be checked with the provider; the app's allowance is explicitly an estimate.

The delivered ZIP is an updated source project, not a signed or hardware-verified app binary.
