import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Button {
                session.toggle()
            } label: {
                ZStack {
                    if session.isStarting {
                        // Loading state — capture is spinning up (permission
                        // prompt + extended runtime session + audio engine).
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.4)
                    } else {
                        Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                    }
                }
                .frame(width: 110, height: 110)
                .background(Circle().fill(Self.recordTint.opacity(session.isStarting ? 0.6 : 1.0)))
                .scaleEffect(session.isRecording ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.12), value: session.isRecording)
                .animation(.easeOut(duration: 0.15), value: session.isStarting)
            }
            .buttonStyle(.plain)
            // Taps are ignored while spinning up so a double-tap can't kick off
            // a second start or stop a half-started session.
            .disabled(session.isStarting)
        }
        .task { WatchSessionManager.shared.activate() }
    }

    private static let recordTint = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)
}

#Preview {
    ContentView()
}
