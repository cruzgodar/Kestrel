import AppIntents
import SwiftUI
import WidgetKit

/// Single static timeline entry — the complication is just a button.
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

/// Watch complication: a bird-glyph button that runs `StartRecordingIntent`,
/// which launches the watch app and starts a session (a no-op if one is
/// already running).
struct StartRecordingComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            label
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) { Color.clear }
        .widgetAccentable()
    }

    @ViewBuilder
    private var label: some View {
        switch family {
        case .accessoryInline:
            Label("Record", systemImage: "bird")
        case .accessoryCircular, .accessoryCorner:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bird")
                    .font(.system(size: 20, weight: .semibold))
            }
        default:
            Image(systemName: "bird")
                .font(.system(size: 20, weight: .semibold))
        }
    }
}

struct StartRecordingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "com.cruzgodar.Kestrel.watchkitapp.StartRecording",
            provider: StartRecordingProvider()
        ) { _ in
            StartRecordingComplicationView()
        }
        .configurationDisplayName("Start Recording")
        .description("Start listening for birds.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
