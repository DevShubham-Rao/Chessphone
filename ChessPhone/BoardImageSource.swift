import AVFoundation
import UIKit

/// Anything that can hand the pipeline one photo of the board.
@MainActor
protocol BoardImageSource: AnyObject {
    /// Get ready (permissions, sessions, streams). Cheap to call repeatedly.
    func prepare() async throws
    func captureImage() async throws -> UIImage
    /// Release the camera / glasses session.
    func shutdown()
}

/// iPhone back camera. Useful for testing the whole pipeline without the glasses
/// (prop the phone up, or hold it over the board).
@MainActor
final class PhoneCameraSource: NSObject, BoardImageSource, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var continuation: CheckedContinuation<UIImage, Error>?
    private var pendingPhotoID: Int64?
    private var captureDeadline: Task<Void, Never>?

    func prepare() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw VisionError.cameraDenied }

        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw VisionError.cameraDenied
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            configured = true
        }

        if !session.isRunning {
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }

            // Do not impose a fixed 0.6 s delay on every cold start. Usually the session
            // becomes live much sooner; give it a short settle only after it is actually running.
            let deadline = Date().addingTimeInterval(1.5)
            while !session.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            guard session.isRunning else { throw VisionError.cameraDenied }
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    func captureImage() async throws -> UIImage {
        try await prepare()
        try Task.checkCancellation()
        guard continuation == nil else { throw VisionError.captureBusy }
        let settings = AVCapturePhotoSettings()
        let photoID = settings.uniqueID
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIImage, Error>) in
                continuation = cont
                pendingPhotoID = photoID
                captureDeadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                    self?.resolvePhoto(id: photoID, result: .failure(VisionError.captureTimeout))
                }
                output.capturePhoto(with: settings, delegate: self)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.resolvePhoto(id: photoID, result: .failure(CancellationError())) }
        })
    }

    func shutdown() {
        if let id = pendingPhotoID { resolvePhoto(id: id, result: .failure(CancellationError())) }
        guard session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        let photoID = photo.resolvedSettings.uniqueID
        Task { @MainActor in
            if let error = error {
                self.resolvePhoto(id: photoID, result: .failure(error))
            } else if let data = data, let image = UIImage(data: data) {
                self.resolvePhoto(id: photoID, result: .success(image))
            } else {
                self.resolvePhoto(id: photoID, result: .failure(VisionError.imageEncodingFailed))
            }
        }
    }

    private func resolvePhoto(id: Int64, result: Result<UIImage, Error>) {
        guard pendingPhotoID == id, let pending = continuation else { return }
        continuation = nil
        pendingPhotoID = nil
        captureDeadline?.cancel()
        captureDeadline = nil
        pending.resume(with: result)
    }
}
