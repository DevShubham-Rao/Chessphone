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
            try? await Task.sleep(nanoseconds: 600_000_000)   // let exposure / focus settle
        }
    }

    func captureImage() async throws -> UIImage {
        try await prepare()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UIImage, Error>) in
            continuation = cont
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func shutdown() {
        guard session.isRunning else { return }
        let session = self.session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            guard let cont = self.continuation else { return }
            self.continuation = nil
            if let error = error {
                cont.resume(throwing: error)
            } else if let data = data, let image = UIImage(data: data) {
                cont.resume(returning: image)
            } else {
                cont.resume(throwing: VisionError.imageEncodingFailed)
            }
        }
    }
}
