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

    private let glasses = GlassesCameraSource()
    private let phone = PhoneCameraSource()
    private let reader = GeminiBoardReader()

    private var source: BoardImageSource { sourceKind == .glasses ? glasses : phone }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "ChessPhone.vision.enabled")
        sourceKind = SourceKind(rawValue: d.string(forKey: "ChessPhone.vision.source") ?? "") ?? .glasses
    }

    /// Start the camera/session ahead of time so continuous watch can use its live frames.
    func warmUp() {
        guard enabled else { return }
        Task {
            do {
                try await source.prepare()
                if case .failed(_) = stage { stage = .idle }
            } catch {
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
        do {
            stage = .capturing
            let image = try await source.captureImage()
            return try await readBoard(from: image, playerColor: playerColor)
        } catch {
            stage = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Captures and reads the first frame when continuous watch starts.
    func captureWatchBaseline(playerColor: PieceColor) async throws -> (ScannedBoard, [UInt8]) {
        guard sourceKind == .glasses else { throw VisionError.glassesUnavailable }
        stage = .capturing
        let image = try await glasses.captureImage()
        guard let fingerprint = BoardFrameMonitor.fingerprint(image) else {
            throw VisionError.imageEncodingFailed
        }
        let board = try await readBoard(from: image, playerColor: playerColor)
        return (board, fingerprint)
    }

    /// Waits for a physical change in the live glasses view without polling Gemini.
    func waitForStableChangedFrame(since fingerprint: [UInt8]) async throws -> (UIImage, [UInt8]) {
        guard sourceKind == .glasses else { throw VisionError.glassesUnavailable }
        return try await glasses.waitForStableChangedFrame(since: fingerprint)
    }

    func readBoard(from image: UIImage, playerColor: PieceColor) async throws -> ScannedBoard {
        do {
            stage = .reading
            let jpeg = try ImagePreprocessor.jpegData(from: image)
            let reading = try await reader.readBoard(jpeg: jpeg)
            let board = try BoardOrienter.orient(reading, playerColor: playerColor)
            stage = .done
            return board
        } catch {
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
            Picker("Camera", selection: $vision.sourceKind) {
                ForEach(VisionCoordinator.SourceKind.allCases) { Text($0.title).tag($0) }
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
