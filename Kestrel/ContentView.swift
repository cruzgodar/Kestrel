import SwiftUI

struct ContentView: View {
    @Environment(RecordingManager.self) private var manager

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            Button {
                Task { await manager.toggle() }
            } label: {
                Label(
                    manager.isRecording ? "Stop Recording" : "Start Recording",
                    systemImage: manager.isRecording ? "stop.fill" : "mic.fill"
                )
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(manager.isRecording ? .red : .accentColor)
            .animation(.snappy, value: manager.isRecording)
        }
    }
}

#Preview {
    ContentView()
        .environment(RecordingManager())
}
