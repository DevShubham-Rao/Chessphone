import SwiftUI
import UIKit
import AVFoundation

/// The desktop command-center workflow adapted to an iPhone screen. No local
/// web server, inbound controls, or virtual microphone is needed on iOS.
struct SessionDashboardView: View {
    @ObservedObject var vm: ChessPhoneViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var journal = SessionJournal.shared
    @ObservedObject private var vision = VisionCoordinator.shared
    @ObservedObject private var recorder = NativeSessionRecorder.shared
    @State private var filter = EventFilter.all
    @State private var manualMove = ""
    @State private var manualError = ""
    @State private var color: PieceColor = .white
    @State private var startingFEN = ""
    @State private var setupError = ""
    @State private var showingDiagnostics = false
    @State private var export: SessionSharePayload?

    private enum EventFilter: String, CaseIterable, Identifiable {
        case all = "All", moves = "Moves", problems = "Problems"
        var id: String { rawValue }
    }

    private var filteredEvents: [SessionEvent] {
        journal.events.reversed().filter { event in
            switch filter {
            case .all: return true
            case .moves: return event.kind.isMove
            case .problems: return event.kind.isProblem
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statusCard
                    if vm.phase != .selectSide {
                        boardCard
                        suggestionCard
                        controlsCard
                    }
                    frameCard
                    videoRecordingCard
                    spendingCard
                    setupCard
                    movesCard
                    recordingCard
                    eventsCard
                    Text("Use advice in practice or in games where everyone has agreed to it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Command Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingDiagnostics = true } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingDiagnostics) { SessionDiagnosticsView(vm: vm) }
            .sheet(item: $export) { payload in SessionShareSheet(urls: payload.urls) }
            .onAppear { vision.livePreviewActive = !vm.sessionPaused }
            .onDisappear {
                vision.livePreviewActive = false
                recorder.stopIfNeeded()
            }
            .onChange(of: vm.sessionPaused) { _, paused in vision.livePreviewActive = !paused }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { recorder.stopIfNeeded() }
            }
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(vm.sessionStatus, systemImage: vm.sessionPaused ? "pause.circle.fill" : "circle.fill")
                    .font(.headline)
                    .foregroundStyle(vm.sessionPaused ? Color.orange : Color.accentColor)
                    .accessibilityLabel("Session status: \(vm.sessionStatus)")
                Text(vm.status).font(.subheadline)
                if vm.phase != .selectSide {
                    HStack {
                        Text("You: \(vm.playerColor.name)")
                        Spacer()
                        Text("Board turn: \(vm.physicalPosition.sideToMove.name)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Button(vm.sessionPaused ? "Resume" : "Pause") {
                        vm.sessionPaused ? vm.resumeSession() : vm.pauseSession()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var boardCard: some View {
        GroupBox("Tracked physical board") {
            BoardView(board: vm.physicalPosition.board, bottomColor: vm.playerColor,
                      lastMove: nil, selected: nil, targets: [], checkSquare: nil,
                      hapticStage: .idle, seatFlipped: vm.seatFlipped)
                .overlay {
                    if let move = vm.suggestionMove {
                        SessionMoveArrow(move: move, bottomColor: vm.playerColor)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Confirmed chessboard. \(vm.suggestionMove.map { "Suggested move \($0.uci)." } ?? "")")
        }
    }

    @ViewBuilder private var suggestionCard: some View {
        if let move = vm.suggestionMove {
            GroupBox("Your suggested move") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.recommendedMoveText.isEmpty ? move.uci.uppercased() : vm.recommendedMoveText)
                        .font(.title2.monospaced().bold())
                    Text(vm.suggestionEvaluationText.isEmpty ? "Evaluation unavailable" : vm.suggestionEvaluationText)
                        .font(.subheadline)
                    ProgressView(value: min(1, max(0, vm.suggestionConfidence)))
                        .tint(.green)
                    Text("The bar represents the engine's position evaluation from your side; it is not camera confidence or a guarantee.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Repeat suggestion") { vm.handleShakeRepeat() }
                        .buttonStyle(.bordered)
                    Button("I played this move") { vm.confirmSuggestedMove() }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.sessionPaused)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var controlsCard: some View {
        GroupBox("Recover or enter a move") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Undo") { vm.undo(); manualError = "" }
                    Button("Check board now") { vm.requestBoardScan() }
                        .disabled(!vision.enabled || vm.sessionPaused || vm.phase != .opponentSourceColumn || vm.tapCount > 0)
                }
                .buttonStyle(.bordered)
                if vm.phase == .engineFailed {
                    Button("Retry engine") { vm.retryEngine() }.buttonStyle(.borderedProminent)
                }
                TextField("Move: Nf3 or g1f3", text: $manualMove)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Manual move in real board coordinates")
                Button("Enter move") {
                    if vm.submitManualMove(manualMove) {
                        manualMove = ""
                        manualError = ""
                    } else { manualError = vm.status }
                }
                .buttonStyle(.bordered)
                .disabled(manualMove.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Use SAN (Nf3, O-O) or real board coordinates (g1f3), even with Black-seat numbering. Add q, r, b, or n for a UCI promotion.")
                    .font(.caption).foregroundStyle(.secondary)
                if !manualError.isEmpty { Text(manualError).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var frameCard: some View {
        GroupBox("Latest camera frame") {
            VStack(alignment: .leading, spacing: 8) {
                if let image = vision.latestFrame {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    if let date = vision.latestFrameDate {
                        Text("Captured \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    frameBadges
                    Text("Analysis badges describe the last analyzed frame; the live preview can be newer.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("No frame yet. Enable board scanning and check the board to capture one.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(vision.stage.text).font(.caption)
                if !vm.scanStatus.isEmpty { Text(vm.scanStatus).font(.caption).foregroundStyle(.secondary) }
                Text("The arrow is shown on the tracked digital board above. Camera corners are not inferred or drawn over this photo.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var frameBadges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let visible = vision.diagnostics.boardVisible {
                Label(visible ? "Board visible" : "Board not readable", systemImage: visible ? "checkmark.circle" : "eye.slash")
            }
            if let hand = vision.diagnostics.handOverBoard {
                Label(hand ? "Hand over board" : "No hand reported", systemImage: hand ? "hand.raised" : "hand.raised.slash")
            }
            if let confidence = vision.diagnostics.confidence { Text("Vision confidence: \(confidence)") }
            if let seconds = vision.diagnostics.latencySeconds { Text(String(format: "Vision response: %.1f s", seconds)) }
            Text(vision.diagnostics.precheckNote)
            if let notes = vision.diagnostics.notes, !notes.isEmpty { Text(notes) }
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private var spendingCard: some View {
        GroupBox("Vision spending estimate") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(vision.estimatedCostUSD.formatted(.currency(code: "USD"))) / \(vision.authorizedCostLimitUSD.formatted(.currency(code: "USD"))) authorized")
                    .font(.headline.monospacedDigit())
                ProgressView(value: min(1, vision.estimatedCostUSD / max(0.001, vision.authorizedCostLimitUSD)))
                    .tint(vision.isBudgetPaused ? .orange : .accentColor)
                Text("\(vision.requestCount) requests • Local motion pre-check \(vision.localGateEnabled ? "on" : "off")")
                    .font(.caption)
                Text("An estimate based on your configured request allowance, not your provider's bill. Retries count too.")
                    .font(.caption).foregroundStyle(.secondary)
                if vision.isBudgetPaused {
                    Text("Spending limit reached. Review scanning settings, then Resume to authorize the next allowance.")
                        .font(.caption).foregroundStyle(.orange)
                }
                NavigationLink("Vision safety settings") { VisionSafetySettingsView() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setupCard: some View {
        GroupBox("New game or recover from a position") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Your side", selection: $color) {
                    Text("White").tag(PieceColor.white)
                    Text("Black").tag(PieceColor.black)
                }
                .pickerStyle(.segmented)
                TextField("Starting FEN (optional)", text: $startingFEN, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text("Leave FEN empty for the starting position. A FEN must include whose turn it is, castling rights, and en passant.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Start game") {
                    if vm.startNewGame(color: color, fen: startingFEN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : startingFEN) {
                        setupError = ""
                        manualError = ""
                    } else { setupError = vm.status }
                }
                .buttonStyle(.borderedProminent)
                Text("Starting a game replaces the current game. Saved session files remain available in Files.")
                    .font(.caption).foregroundStyle(.secondary)
                if !setupError.isEmpty { Text(setupError).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var movesCard: some View {
        GroupBox("Moves") {
            VStack(alignment: .leading, spacing: 6) {
                if vm.moveListText.isEmpty {
                    Text("No moves yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(vm.moveListText.enumerated()), id: \.offset) { row in
                        Text(row.element).font(.system(.subheadline, design: .monospaced))
                    }
                }
                if vm.phase != .selectSide {
                    DisclosureGroup("Current FEN") {
                        Text(vm.physicalPosition.fen)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recordingCard: some View {
        GroupBox("Session files") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Save events and PGN on this iPhone", isOn: $journal.recordingEnabled)
                Toggle("Also save key camera frames", isOn: $journal.saveKeyFrames)
                    .disabled(!journal.recordingEnabled)
                Text("Run files are stored in Documents/ChessPhone Sessions. Photos can include people and rooms; they are saved only when both options are on. Turning recording on mid-game saves the most recent 300 events and all future events.")
                    .font(.caption).foregroundStyle(.secondary)
                if let folder = journal.sessionFolder {
                    Text(folder.lastPathComponent).font(.caption2.monospaced()).textSelection(.enabled)
                }
                Button { export = SessionSharePayload(urls: journal.exportURLs()) } label: {
                    Label("Share session files", systemImage: "square.and.arrow.up")
                }
                .disabled(journal.sessionFolder == nil)
                if !journal.storageError.isEmpty {
                    Text(journal.storageError).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var videoRecordingCard: some View {
        GroupBox("Record command center video") {
            VStack(alignment: .leading, spacing: 10) {
                Label(recorder.status, systemImage: recorder.isRecording ? "record.circle.fill" : "video")
                    .font(.subheadline)
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.primary)
                if recorder.isRecording {
                    Button("Stop and save video") { recorder.stopRecording() }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.isBusy)
                } else {
                    Button(recorder.isBusy ? "Starting…" : "Start screen recording") { recorder.startRecording() }
                        .buttonStyle(.borderedProminent)
                        .disabled(recorder.isBusy)
                }
                if let movie = recorder.latestRecordingURL {
                    Button { export = SessionSharePayload(urls: [movie]) } label: {
                        Label("Share saved MP4", systemImage: "square.and.arrow.up")
                    }
                    .disabled(recorder.isRecording || recorder.isBusy)
                    Text(movie.lastPathComponent).font(.caption2.monospaced()).textSelection(.enabled)
                }
                Text("Records the app display and available app audio, with the microphone off. Keep the board and preview visible for your recording. iOS asks for screen-recording permission. Leaving Command Center or backgrounding the app finishes the clip.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Movies are saved in Documents/ChessPhone Recordings and can be shared as MP4 files.")
                    .font(.caption).foregroundStyle(.secondary)
                if !recorder.lastError.isEmpty {
                    Text(recorder.lastError).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var eventsCard: some View {
        GroupBox("Session log") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Log filter", selection: $filter) {
                    ForEach(EventFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Latest 300 events • newest first").font(.caption2).foregroundStyle(.secondary)
                if filteredEvents.isEmpty {
                    Text("No events in this view.").font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredEvents) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(event.kind.rawValue).font(.caption2.bold())
                                Spacer()
                                Text(event.timestamp, style: .time).font(.caption2.monospacedDigit())
                            }
                            .foregroundStyle(.secondary)
                            Text(event.message).font(.subheadline)
                            if !event.details.isEmpty {
                                DisclosureGroup("Details") {
                                    ForEach(event.details.keys.sorted(), id: \.self) { key in
                                        Text("\(key): \(event.details[key] ?? "")")
                                            .font(.system(.caption2, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                    }
                                }
                                .font(.caption)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

/// Draw the suggestion using the exact same coordinate transform as BoardView.
private struct SessionMoveArrow: Shape {
    let move: Move
    let bottomColor: PieceColor

    func path(in rect: CGRect) -> Path {
        let label: CGFloat = 20
        let cell = (min(rect.width, rect.height) - label) / 8
        func center(_ square: Int) -> CGPoint {
            let file = Square.file(square), rank = Square.rank(square)
            let x = bottomColor == .white ? file : 7 - file
            let y = bottomColor == .white ? 7 - rank : rank
            return CGPoint(x: label + (CGFloat(x) + 0.5) * cell, y: (CGFloat(y) + 0.5) * cell)
        }
        let from = center(move.from), to = center(move.to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head = cell * 0.3
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        path.move(to: CGPoint(x: to.x - head * cos(angle - .pi / 5), y: to.y - head * sin(angle - .pi / 5)))
        path.addLine(to: to)
        path.addLine(to: CGPoint(x: to.x - head * cos(angle + .pi / 5), y: to.y - head * sin(angle + .pi / 5)))
        return path
    }
}

private struct SessionSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct SessionShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct SessionDiagnosticsView: View {
    @ObservedObject var vm: ChessPhoneViewModel
    @ObservedObject private var vision = VisionCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var engineCheck = ""
    @State private var checkingEngine = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Stockfish") {
                    Text(vm.engineStatus)
                    diagnosticRow("Large NNUE network", ready: Bundle.main.url(forResource: "nn-1111cefa1111", withExtension: "nnue") != nil)
                    diagnosticRow("Small NNUE network", ready: Bundle.main.url(forResource: "nn-37f18f62d772", withExtension: "nnue") != nil)
                    Button(checkingEngine ? "Checking…" : "Check engine") {
                        checkingEngine = true
                        Task {
                            let ready = await EngineManager.shared.ensureStarted()
                            engineCheck = ready ? "Stockfish is ready." : EngineManager.shared.lastError
                            checkingEngine = false
                        }
                    }
                    .disabled(checkingEngine || vm.phase == .engineCalculating)
                    if !engineCheck.isEmpty { Text(engineCheck).font(.caption) }
                }
                Section("Board reading") {
                    diagnosticRow("Gemini key available", ready: GeminiKeyProvider.hasKey)
                    Text("Source: \(vision.sourceKind.title)")
                    Text(vision.stage.text)
                    Text("iPhone camera permission: \(cameraPermission)")
                    Text("Meta SDK: \(metaSDKStatus)")
                    Text("Camera permission is requested when you choose a capture. Use scanning settings to register glasses or save a key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Audio") {
                    Text("Output: \(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", "))")
                    Button("Test speech") { SpeechEngine.shared.speakSample() }
                    Text("Speech follows iOS audio routing. This app does not inject a microphone into WhatsApp.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Session storage") {
                    Text(SessionJournal.shared.recordingEnabled ? "Recording enabled" : "Recording off")
                    Text("Session files use the app's Documents folder. A real iPhone is required to verify glasses, volume buttons, speech routes, and haptics.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func diagnosticRow(_ title: String, ready: Bool) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ready ? Color.green : Color.orange)
    }

    private var cameraPermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "allowed"
        case .denied: return "denied — change in iPhone Settings"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested yet"
        @unknown default: return "unknown"
        }
    }

    private var metaSDKStatus: String {
        #if canImport(MWDATCore) && canImport(MWDATCamera)
        return "included"
        #else
        return "not linked — use iPhone camera"
        #endif
    }
}
