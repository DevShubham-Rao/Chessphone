import SwiftUI
import MediaPlayer
import CoreMotion

struct ContentView: View {
    @StateObject private var vm = ChessPhoneViewModel()
    private let motion = CMMotionManager()

    var body: some View {
        ZStack {
            // Hidden MPVolumeView, required so the app is allowed to
            // read/drive system volume at all. Placed off-screen.
            VolumeViewContainer()
                .frame(width: 1, height: 1)
                .position(x: -100, y: -100)

            if vm.phase == .selectSide {
                HStack {
                    Button("BLACK") { vm.selectColor("BLACK") }
                        .padding().background(Color.black).foregroundColor(.white)
                    Button("WHITE") { vm.selectColor("WHITE") }
                        .padding().background(Color.white).foregroundColor(.black)
                }
            } else {
                VStack {
                    Text("Phase: \(String(describing: vm.phase))")
                    Text("Taps: \(vm.tapCount)")
                    Text("Vol up = count, vol down = confirm, shake = repeat")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .onAppear {
            VolumeButtonHandler.shared.onVolumeUp = { vm.handleVolumeUp() }
            VolumeButtonHandler.shared.onVolumeDown = { vm.handleVolumeDown() }
            VolumeButtonHandler.shared.start()
            startShakeDetection()
        }
        .onDisappear {
            VolumeButtonHandler.shared.stop()
            motion.stopAccelerometerUpdates()
        }
    }

    private func startShakeDetection() {
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { data, _ in
            guard let d = data else { return }
            let magnitude = sqrt(d.acceleration.x * d.acceleration.x +
                                  d.acceleration.y * d.acceleration.y +
                                  d.acceleration.z * d.acceleration.z)
            if magnitude > 2.5 {
                vm.handleShakeRepeat()
            }
        }
    }
}

struct VolumeViewContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        MPVolumeSetter.volumeView = view
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
