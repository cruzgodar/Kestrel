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
                Image(systemName: "bird")
                    .font(.system(size: 22, weight: .semibold))
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

@main
struct KestrelWidgetBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingWidget()
    }
}
