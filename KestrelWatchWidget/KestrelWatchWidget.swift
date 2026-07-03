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

    /// The Kestrel head glyph. `.renderingMode(.original)` keeps its two-tone
    /// purple on full-color faces; accented/vibrant faces flatten it to a clean
    /// silhouette using the image's alpha. An explicit square frame is required:
    /// a bare `.resizable()` image has no intrinsic size, so without one it both
    /// overflows the complication and collapses to nothing in the gallery.
    private func glyph(size: CGFloat) -> some View {
        Image("Complication")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .widgetAccentable()
    }

    @ViewBuilder
    private var label: some View {
        switch family {
        case .accessoryInline:
            // Inline shows a single line of tinted text with a leading glyph;
            // it renders images as templates, so we lean on an SF Symbol here.
            Label("Kestrel", systemImage: "bird.fill")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                // Faint purple wash over the standard gray background.
                Self.purple.opacity(0.05)
                // Near-fills the ~44pt disc with a slim inset from the edge.
                glyph(size: 40)
            }
        case .accessoryCorner:
            glyph(size: 40)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                glyph(size: 48)
                Text("Kestrel")
                    .font(.headline)
                    .foregroundStyle(Self.glyphPurple)
                Spacer(minLength: 0)
            }
        default:
            glyph(size: 40)
        }
    }
}

// MARK: - Previews
//
// These render the complication in Xcode's canvas for every family, and the
// canvas exposes the full-color / accented / vibrant rendering modes — so the
// on-watch appearance can be verified without deploying to a device.

#Preview("Circular", as: .accessoryCircular) {
    StartRecordingComplication()
} timeline: {
    StartRecordingEntry(date: .now)
}

#Preview("Corner", as: .accessoryCorner) {
    StartRecordingComplication()
} timeline: {
    StartRecordingEntry(date: .now)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    StartRecordingComplication()
} timeline: {
    StartRecordingEntry(date: .now)
}

#Preview("Inline", as: .accessoryInline) {
    StartRecordingComplication()
} timeline: {
    StartRecordingEntry(date: .now)
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
