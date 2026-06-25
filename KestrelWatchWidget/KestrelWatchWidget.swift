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

/// Watch complication: a bird-glyph button that simply opens the watch app.
/// Tapping a complication launches its host app by default, so no `widgetURL`
/// or intent is attached — the user starts the session from the app's own
/// record button rather than the tap kicking off a walk immediately.
struct StartRecordingComplicationView: View {
    @Environment(\.widgetFamily) private var family

    /// The start-recording button's purple. Used filled for the glyph and as a
    /// light wash on the complication background.
    private static let purple = Color(red: 0.6, green: 0.5, blue: 1.0)
    private static let glyphPurple = Color(red: 0.6, green: 0.5, blue: 1.0)

    var body: some View {
        label
            .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private var label: some View {
        switch family {
        case .accessoryInline:
            Label("Record", systemImage: "bird.fill")
        case .accessoryCircular, .accessoryCorner:
            ZStack {
                AccessoryWidgetBackground()
                // Faint purple tint over the standard gray background.
                Self.purple.opacity(0.05)
                Image(systemName: "bird.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Self.glyphPurple)
            }
        default:
            Image(systemName: "bird.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Self.glyphPurple)
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
        .configurationDisplayName("Open Kestrel")
        .description("Open Kestrel to listen for birds.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
