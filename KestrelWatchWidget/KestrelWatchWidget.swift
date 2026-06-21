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

/// Watch complication: a bird-glyph button that opens the watch app via a
/// deep link (`widgetURL`) and starts a session (a no-op if one is already
/// running). A `widgetURL` is used rather than `Button(intent:)` because the
/// intent's `perform()` runs in the widget extension's process — its in-app
/// notification and `UserDefaults` flag never reach the app, so the tap only
/// foregrounded the app without starting a recording. The URL is delivered to
/// the app's `onOpenURL` in-process, which fires the request reliably.
struct StartRecordingComplicationView: View {
    @Environment(\.widgetFamily) private var family

    /// The start-recording button's purple (matches the app's record button:
    /// hue 252°). Used filled for the glyph and as a light wash on the
    /// complication background.
    private static let purple = Color(hue: 252.0 / 360.0, saturation: 0.65, brightness: 1.0)

    var body: some View {
        label
            .containerBackground(for: .widget) { Color.clear }
            .widgetURL(RecordingIntentRequest.startRecordingURL)
    }

    @ViewBuilder
    private var label: some View {
        switch family {
        case .accessoryInline:
            Label("Record", systemImage: "bird.fill")
        case .accessoryCircular, .accessoryCorner:
            ZStack {
                AccessoryWidgetBackground()
                // Slight purple tint over the standard gray background.
                Self.purple.opacity(0.35)
                Image(systemName: "bird.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Self.purple)
            }
        default:
            Image(systemName: "bird.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Self.purple)
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
