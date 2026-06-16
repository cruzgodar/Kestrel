import SwiftUI

struct ContentView: View {
    @State private var session = WatchSessionManager.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Button {
                session.toggle()
            } label: {
                Image(systemName: session.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace, options: .speed(2.6)))
                    .frame(width: 110, height: 110)
                    .background(Circle().fill(Self.recordTint))
                    .scaleEffect(session.isRecording ? 1.05 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: session.isRecording)
            }
            .buttonStyle(.plain)
        }
        .task { WatchSessionManager.shared.activate() }
    }

    private static let recordTint = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)
}

#Preview {
    ContentView()
}
