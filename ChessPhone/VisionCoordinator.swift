import SwiftUI

/// Orchestrates: capture -> compress -> Gemini -> oriented board. Pure "photo to board";
/// all chess decisions stay in ChessPhoneViewModel.
@MainActor
final class VisionCoordinator: ObservableObject {
    static let shared = VisionCoordinator()

    enum SourceKind: String, CaseIterable, Identifiable {
        case glasses, phone
        var id: String { rawValue }
        var title: String { self == .glasses ? "Ray-Ban Meta glasses" : "iPhone camera (testing)" }
    }

    enum Stage: Equatable {
        case idle, capturing, reading, done
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Ready."
            case .capturing: return "Taking photo..."
            case .reading: return "Reading board..."
            case .done: return "Board read."
            case .failed(let why): return "Failed: \(why)"
            }
        }
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "ChessPhone.vision.enabled")
            enabled ? warmUp() : shutdown()
        }
    }
    @Published var sourceKind: SourceKind {
        didSet {
            UserDefaults.standard.set(sourceKind.rawValue, forKey: "ChessPhone.vision.source")
            shutdown()
            if enabled { warmUp() }
        }
    }
    @Published private(set) var stage: Stage = .idle
    @Published var localGateEnabled: Bool {
        didSet { UserDefaults.standard.set(localGateEnabled, forKey: "ChessPhone.vision.localGate") }
    }
    @Published var maxCostUSD: Double {
        didSet {
            UserDefaults.standard.set(VisionBudget.validLimit(maxCostUSD), forKey: "ChessPhone.vision.maxCost")
            allowance.updateLimitBeforeFirstRequest(maxCostUSD)
            isBudgetPaused = allowance.isPaused
        }
    }
    @Published var estimatedRequestCostUSD: Double {
        didSet { UserDefaults.standard.set(VisionBudget.validEstimate(estimatedRequestCostUSD), forKey: "ChessPhone.vision.requestEstimate") }
    }
    @Published private var allowance: VisionBudget
    @Published private(set) var isBudgetPaused = false
    @Published private(set) var latestFrame: UIImage?
    @Published private(set) var latestFrameDate: Date?
    @Published private(set) var latestAnalyzedFrame: UIImage?
    @Published var livePreviewActive = false
    @Published private(set) var diagnostics = VisionFrameDiagnostics()

    var estimatedCostUSD: Double { allowance.estimatedCostUSD }
    var authorizedCostLimitUSD: Double { allowance.authorizedCostLimitUSD }
    var requestCount: Int { allowance.requestCount }

    private let glasses = GlassesCameraSource()
    private let phone = PhoneCameraSource()
    private let reader = GeminiBoardReader()
    private var activeReadID: UUID?
    /// A reset invalidates every suspended capture/read without letting its late
    /// result, retry, or cleanup mutate the next game's budget and diagnostics.
    private var sessionGeneration = 0

    private var source: BoardImageSource { sourceKind == .glasses ? glasses : phone }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "ChessPhone.vision.enabled")
        sourceKind = SourceKind(rawValue: d.string(forKey: "ChessPhone.vision.source") ?? "") ?? .glasses
        localGateEnabled = d.object(forKey: "ChessPhone.vision.localGate") as? Bool ?? true
        let configuredLimit = VisionBudget.validLimit(d.object(forKey: "ChessPhone.vision.maxCost") as? Double ?? 10)
        maxCostUSD = configuredLimit
        estimatedRequestCostUSD = VisionBudget.validEstimate(d.object(forKey: "ChessPhone.vision.requestEstimate") as? Double ?? 0.01)
        allowance = VisionBudget(limitUSD: configuredLimit)
        glasses.onPreviewFrame = { [weak self] image, date in
            guard let self, self.livePreviewActive, !self.isBudgetPaused else { return }
            self.latestFrame = image
            self.latestFrameDate = date
        }
    }

    /// Resume preserves the tally and explicitly authorizes another allowance block.
    func resumeBudget() {
        guard allowance.isPaused else { return }
        allowance.resume(additionalLimitUSD: maxCostUSD)
        isBudgetPaused = allowance.isPaused
        stage = .idle
        ChessDebugLog.shared.record("BUDGET", "Vision allowance extended", details: "Estimated total: \(estimatedCostUSD); authorized total: \(authorizedCostLimitUSD) USD")
    }

    func resetSessionBudget() {
        sessionGeneration += 1
        activeReadID = nil
        allowance.reset(limitUSD: maxCostUSD)
        isBudgetPaused = false
        diagnostics = VisionFrameDiagnostics()
        latestFrame = nil
        latestFrameDate = nil
        latestAnalyzedFrame = nil
        stage = .idle
    }

    private func reserveRequest() throws {
        try Task.checkCancellation()
        defer { isBudgetPaused = allowance.isPaused }
        do {
            try allowance.reserve(estimatedRequestCostUSD: estimatedRequestCostUSD)
        } catch {
            stage = .failed(VisionError.budgetReached.localizedDescription)
            ChessDebugLog.shared.record("BUDGET", "Estimated vision allowance reached", details: "\(requestCount) attempts; estimated \(estimatedCostUSD) of \(authorizedCostLimitUSD) USD. No further request was sent.")
            SessionJournal.shared.record(.paused, "Estimated vision allowance reached. Paused.", details: ["estimatedCostUSD": String(estimatedCostUSD), "authorizedCostLimitUSD": String(authorizedCostLimitUSD)])
            throw error
        }
    }

    /// Start the camera/session ahead of time so continuous watch can use its live frames.
    func warmUp() {
        guard enabled else { return }
        let generation = sessionGeneration
        Task {
            do {
                try await source.prepare()
                guard generation == sessionGeneration, !Task.isCancelled else { return }
                if case .failed(_) = stage { stage = .idle }
            } catch {
                guard generation == sessionGeneration, !Task.isCancelled else { return }
                // Surface warm-up failures instead of silently discarding them. A later scan
                // still calls prepare() again, so reconnecting the glasses can recover normally.
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func shutdown() {
        glasses.shutdown()
        phone.shutdown()
    }

    func captureAndRead(playerColor: PieceColor) async throws -> ScannedBoard {
        guard !isBudgetPaused else { throw VisionError.budgetReached }
        guard activeReadID == nil else { throw VisionError.captureBusy }
        let generation = sessionGeneration
        diagnostics.precheckNote = "Manual scan: local motion pre-check bypassed"
        do {
            stage = .capturing
            await ChessDebugLog.shared.record("CAMERA", "Capturing board", details: "Source: \(sourceKind.title)\nPlayer color: \(playerColor.name)")
            let image = try await source.captureImage()
            try Task.checkCancellation()
            guard generation == sessionGeneration else { throw CancellationError() }
            return try await readBoard(from: image, playerColor: playerColor)
        } catch {
            guard generation == sessionGeneration else { throw CancellationError() }
            if error is CancellationError || Task.isCancelled {
                if activeReadID == nil { stage = .idle }
                throw CancellationError()
            }
            await ChessDebugLog.shared.record("ERROR", "Camera capture or board read failed", details: error.localizedDescription)
            stage = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Captures and reads the first frame when continuous watch starts.
    func captureWatchBaseline(playerColor: PieceColor) async throws -> (ScannedBoard, [UInt8]) {
        guard !isBudgetPaused else { throw VisionError.budgetReached }
        guard activeReadID == nil else { throw VisionError.captureBusy }
        guard sourceKind == .glasses else { throw VisionError.glassesUnavailable }
        let generation = sessionGeneration
        diagnostics.precheckNote = "Initial frame: baseline board read"
        stage = .capturing
        let image = try await glasses.captureImage()
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let fingerprint = BoardFrameMonitor.fingerprint(image) else {
            throw VisionError.imageEncodingFailed
        }
        let board = try await readBoard(from: image, playerColor: playerColor)
        return (board, fingerprint)
    }

    /// Waits for a physical change in the live glasses view without polling Gemini.
    func waitForStableChangedFrame(since fingerprint: [UInt8]) async throws -> (UIImage, [UInt8]) {
        guard sourceKind == .glasses else { throw VisionError.glassesUnavailable }
        guard !isBudgetPaused else { throw VisionError.budgetReached }
        let generation = sessionGeneration
        if localGateEnabled {
            diagnostics.precheckNote = "Local pre-check: waiting for motion, then a steady board"
            let next = try await glasses.waitForStableChangedFrame(since: fingerprint)
            try Task.checkCancellation()
            guard generation == sessionGeneration else { throw CancellationError() }
            diagnostics.precheckNote = "Local pre-check: motion settled; reading frame"
            return next
        }
        // An opt-out still limits polling to one frame every three seconds.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try Task.checkCancellation()
        let image = try await glasses.captureImage()
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
        guard let next = BoardFrameMonitor.fingerprint(image) else { throw VisionError.imageEncodingFailed }
        diagnostics.precheckNote = "Local pre-check off: timed frame read"
        return (image, next)
    }

    func readBoard(from image: UIImage, playerColor: PieceColor) async throws -> ScannedBoard {
        try Task.checkCancellation()
        guard !isBudgetPaused else { throw VisionError.budgetReached }
        // Manual scans, the watcher, and Board Trainer share this gate and allowance.
        guard activeReadID == nil else { throw VisionError.captureBusy }
        let generation = sessionGeneration
        let readID = UUID()
        activeReadID = readID
        defer {
            if activeReadID == readID { activeReadID = nil }
        }
        let started = ProcessInfo.processInfo.systemUptime
        latestFrame = image
        latestFrameDate = Date()
        latestAnalyzedFrame = image
        if diagnostics.precheckNote == "No frame checked yet" {
            diagnostics.precheckNote = "Photo read: local motion pre-check bypassed"
        }
        diagnostics.timestamp = Date()
        diagnostics.boardVisible = nil
        diagnostics.handOverBoard = nil
        diagnostics.confidence = nil
        diagnostics.latencySeconds = nil
        diagnostics.notes = nil
        do {
            try Task.checkCancellation()
            stage = .reading
            let rotate180 = playerColor == .black
            let jpeg = try ImagePreprocessor.jpegData(from: image, rotate180: rotate180)
            await ChessDebugLog.shared.record("IMAGE", "Image prepared for Gemini", details: "Original image: \(Int(image.size.width))×\(Int(image.size.height)) points\nJPEG sent: \(jpeg.count) bytes\nPlayer color: \(playerColor.name)\nCamera view normalized: \(rotate180 ? "rotated 180° to White-seat view" : "already White-seat view")\nOutput coordinates: rank 8 to rank 1, file a to file h")
            let reading = try await reader.readBoard(jpeg: jpeg, beforeRequest: { [weak self] in
                guard let self, self.sessionGeneration == generation,
                      self.activeReadID == readID else { throw CancellationError() }
                try self.reserveRequest()
            })
            try Task.checkCancellation()
            guard generation == sessionGeneration, activeReadID == readID else { throw CancellationError() }
            diagnostics.boardVisible = reading.boardVisible
            diagnostics.handOverBoard = reading.handOverBoard
            diagnostics.confidence = reading.confidence
            diagnostics.notes = reading.notes
            diagnostics.latencySeconds = ProcessInfo.processInfo.systemUptime - started
            let board = try BoardOrienter.orient(reading)
            SessionJournal.shared.record(.frame, "Board frame read.", details: ["confidence": reading.confidence, "latencySeconds": String(diagnostics.latencySeconds ?? 0), "precheck": diagnostics.precheckNote])
            SessionJournal.shared.saveFrame(jpeg, label: "board-read")
            await ChessDebugLog.shared.record("BOARD", "Gemini board mapped to fixed chess coordinates", details: "Player color: \(playerColor.name)\nConfidence: \(board.confidence)\nNotes: \(board.notes ?? "<none>")\nBoard (rank 8 at top, file a at left):\n\(ChessDebugFormat.board(board.squares))")
            stage = .done
            return board
        } catch {
            guard generation == sessionGeneration, activeReadID == readID else { throw CancellationError() }
            diagnostics.latencySeconds = ProcessInfo.processInfo.systemUptime - started
            diagnostics.notes = error.localizedDescription
            if error is CancellationError {
                stage = .idle
                throw error
            }
            await ChessDebugLog.shared.record("ERROR", "Board scan pipeline failed", details: error.localizedDescription)
            SessionJournal.shared.record(.problem, "Board scan failed.", details: ["reason": error.localizedDescription])
            stage = .failed(error.localizedDescription)
            throw error
        }
    }
}

/// Drop this inside the Form in HapticSettingsView.
struct VisionSettingsSection: View {
    @ObservedObject private var vision = VisionCoordinator.shared
    @State private var keyDraft = ""
    @State private var keyStatus = GeminiKeyProvider.hasKey ? "A Gemini key is available." : "No Gemini key yet."
    @State private var glassesStatus = ""

    var body: some View {
        Section(header: Text("Board scanning"),
                footer: Text(vision.sourceKind == .glasses
                    ? "When on, ChessPhone watches the Ray-Ban live camera view and checks the board after it settles. Keep the board in view. Volume Up remains available for manual move entry."
                    : "Continuous watch requires Ray-Ban Meta glasses. With the iPhone camera selected, use Check board now to read the board manually.")) {
            Toggle("Continuous board watch", isOn: $vision.enabled)
            NavigationLink(destination: VisionSafetySettingsView()) {
                Label("Vision allowance & pre-check", systemImage: "dollarsign.circle")
            }
            Picker("Camera", selection: $vision.sourceKind) {
                ForEach(VisionCoordinator.SourceKind.allCases) { Text($0.title).tag($0) }
            }
            Picker("Board reader", selection: Binding(
                get: { ChessRecognitionMode(rawValue: UserDefaults.standard.string(forKey: "ChessPhone.recognition.mode") ?? "gemini") ?? .gemini },
                set: { UserDefaults.standard.set($0.rawValue, forKey: "ChessPhone.recognition.mode") }
            )) {
                Text("Gemini").tag(ChessRecognitionMode.gemini)
                Text("My local model").tag(ChessRecognitionMode.local).disabled(!ChessRecognitionMode.localModelInstalled)
            }
            Text(ChessRecognitionMode.localModelInstalled
                 ? "Choose Gemini or the installed chess model."
                 : "Gemini is ready. My local model becomes selectable after a trained ChessBoardClassifier model is added to a future build.")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink(destination: BoardTrainerView()) {
                Label("Board Trainer & Data Export", systemImage: "brain.head.profile")
            }
            if vision.sourceKind == .glasses {
                Button("Connect Ray-Ban Meta glasses") {
                    Task {
                        do {
                            try await GlassesSetup.startRegistration()
                            glassesStatus = "Meta AI opened for registration/approval."
                        } catch {
                            glassesStatus = "Could not start registration: \(error.localizedDescription)"
                        }
                    }
                }
                if !glassesStatus.isEmpty {
                    Text(glassesStatus).font(.caption).foregroundColor(.secondary)
                }
            }
            SecureField("Gemini API key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save key to Keychain") {
                GeminiKeyProvider.save(keyDraft)
                keyDraft = ""
                keyStatus = GeminiKeyProvider.hasKey ? "Key saved." : "Could not save the key."
            }
            Text(keyStatus).font(.caption).foregroundColor(.secondary)
            Text(vision.stage.text).font(.caption).foregroundColor(.secondary)
        }
    }
}
