import AppIntents
import SwiftUI
import WidgetKit

/// Single static timeline entry — the widget is just a button, so it never
/// needs to refresh on a schedule.
struct StartRecordingEntry: TimelineEntry {
    let date: Date
}

struct StartRecordingProvider: TimelineProvider {
    func placeholder(in context: Context) -> StartRecordingEntry {
        StartRecordingEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (StartRecordingEntry) -> Void) {
        completion(StartRecordingEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StartRecordingEntry>) -> Void) {
        completion(Timeline(entries: [StartRecordingEntry(date: .now)], policy: .never))
    }
}

/// Lock-screen accessory widget: a single bird-glyph button that runs
/// `StartRecordingIntent`, which foregrounds the app and starts a session
/// (a no-op if one is already running).
struct StartRecordingWidgetView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Button(intent: StartRecordingIntent()) {
                // Monochrome kestrel-head glyph; lock-screen widgets render
                // vibrant, so the template silhouette tints to the face color.
                Image("KestrelMono")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    // Matches the watch complication: near-fills the ~44pt disc.
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetAccentable()
    }
}

struct StartRecordingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.cruzgodar.Kestrel.StartRecording",
            provider: StartRecordingProvider()
        ) { _ in
            StartRecordingWidgetView()
        }
        .configurationDisplayName("Start Recording")
        .description("Start listening for birds.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Control Center button (iOS 18+): starts a recording via the same
/// `StartRecordingIntent` as the lock-screen widget. Control Center doesn't
/// reliably render custom template images, so it uses the `bird` SF Symbol.
@available(iOS 18.0, *)
struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.cruzgodar.Kestrel.StartRecordingControl") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record", systemImage: "bird")
            }
        }
        .displayName("Start Recording")
        .description("Start listening for birds.")
    }
}

@main
struct KestrelWidgetBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingWidget()
        if #available(iOS 18.0, *) {
            StartRecordingControl()
        }
    }
}
