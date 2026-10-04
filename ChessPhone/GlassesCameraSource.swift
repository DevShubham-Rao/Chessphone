import UIKit

// Ray-Ban Meta camera via Meta's Wearables Device Access Toolkit (DAT), developer preview.
// Everything is behind canImport so the app still builds (e.g. on your CI) before the SDK is added.
// API names follow Meta's iOS integration guide; the SDK is a preview, so if a name changed,
// the compiler will point at it - check https://wearables.developer.meta.com/docs/reference/ios_swift/dat/latest

#if canImport(MWDATCore) && canImport(MWDATCamera)
import MWDATCore
import MWDATCamera

enum GlassesSetup {
    /// Call once at launch (ChessPhoneApp.init).
    static func configure() {
        do { try Wearables.configure() } catch { print("ChessPhone: Wearables.configure failed: \(error)") }
    }

    /// One-time: opens the Meta AI app so the user can approve this app, then returns via URL scheme.
    static func startRegistration() {
        do { try Wearables.shared.startRegistration() } catch { print("ChessPhone: registration failed: \(error)") }
    }

    /// Call from .onOpenURL - the Meta AI app calls back with the registration / permission result.
    static func handle(url: URL) {
        Task { _ = try? await Wearables.shared.handleUrl(url) }
    }
}

@MainActor
final class GlassesCameraSource: BoardImageSource {
    private var session: DeviceSession?
    private var stopStream: (() -> Void)?
    private var requestPhoto: (() -> Void)?
    private var tokens: [Any] = []                 // listener tokens; must stay alive
    private var watcher: Task<Void, Never>?

    private var sessionStarted = false
    private var streamLive = false
    private var captureID = 0
    private var photoContinuation: CheckedContinuation<Data, Error>?

    // MARK: Lifecycle

    func prepare() async throws {
        if sessionStarted, streamLive, requestPhoto != nil { return }   // already warm
        teardown()

        let wearables = Wearables.shared

        var permission = try await wearables.checkPermissionStatus(.camera)
        if permission != .granted { permission = try await wearables.requestPermission(.camera) }
        guard permission == .granted else { throw VisionError.glassesPermissionDenied }

        let newSession = try wearables.createSession(deviceSelector: AutoDeviceSelector(wearables: wearables))
        let states = newSession.stateStream()          // obtain BEFORE start()
        watcher = Task { [weak self] in
            for await state in states { self?.sessionStarted = (state == .started) }
            self?.sessionStarted = false
        }
        try newSession.start()
        guard await waitUntil(8, { sessionStarted }) else { teardown(); throw VisionError.glassesUnavailable }
        session = newSession

        // Low frame rate leaves more Bluetooth bandwidth per frame -> less compression on each image.
        let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 7)
        guard let camera = try newSession.addCamera(config: config) else {
            teardown(); throw VisionError.glassesUnavailable
        }
        let stream = camera.stream

        tokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in self?.streamLive = (state == .streaming) }
        })
        tokens.append(stream.photoDataPublisher.listen { [weak self] photo in
            let data = photo.data
            Task { @MainActor in
                guard let self else { return }
                self.resolvePhoto(.success(data), id: self.captureID)
            }
        })

        stopStream = { stream.stop() }                 // verify name against the API reference
        requestPhoto = { _ = stream.capturePhoto(format: .jpeg) }
        stream.start()

        guard await waitUntil(10, { streamLive }) else { teardown(); throw VisionError.glassesUnavailable }
    }

    func captureImage() async throws -> UIImage {
        try await prepare()
        guard let requestPhoto else { throw VisionError.glassesUnavailable }

        captureID += 1
        let id = captureID
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            photoContinuation = continuation
            requestPhoto()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.resolvePhoto(.failure(VisionError.captureTimeout), id: id)
            }
        }
        guard let image = UIImage(data: data) else { throw VisionError.imageEncodingFailed }
        return image
    }

    func shutdown() { teardown() }

    // MARK: Helpers

    private func resolvePhoto(_ result: Result<Data, Error>, id: Int) {
        guard id == captureID, let continuation = photoContinuation else { return }
        photoContinuation = nil
        continuation.resume(with: result)
    }

    private func teardown() {
        stopStream?()
        session?.stop()
        watcher?.cancel()
        watcher = nil
        tokens.removeAll()
        stopStream = nil
        requestPhoto = nil
        session = nil
        sessionStarted = false
        streamLive = false
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }
}

#else

// SDK not added yet: same API surface, so the rest of the app compiles unchanged.
enum GlassesSetup {
    static func configure() {}
    static func startRegistration() {}
    static func handle(url: URL) {}
}

@MainActor
final class GlassesCameraSource: BoardImageSource {
    func prepare() async throws { throw VisionError.sdkNotLinked }
    func captureImage() async throws -> UIImage { throw VisionError.sdkNotLinked }
    func shutdown() {}
}

#endif
