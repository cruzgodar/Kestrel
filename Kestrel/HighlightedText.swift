import SwiftUI
import UIKit

/// Inline rich text that renders certain phrases with a rounded, tinted
/// background "pill" instead of colored text. Plain runs wrap word-by-word so
/// the paragraph reflows normally; each highlighted phrase is laid out as a
/// single atomic pill (it moves to the next line whole rather than breaking
/// mid-phrase), so its rounded corners always stay intact.
///
/// The pill tints match the Identify tab's row backgrounds — blue for starred
/// birds, purple for birds not yet on the life list — so the copy points at the
/// controls it describes.
struct HighlightedText: View {
    struct Segment {
        var text: String
        var highlight: Color?
        init(_ text: String, highlight: Color? = nil) {
            self.text = text
            self.highlight = highlight
        }
    }

    let segments: [Segment]
    var textStyle: UIFont.TextStyle = .body
    var textColor: Color = .primary
    var alignment: HorizontalAlignment = .leading

    @Environment(\.colorScheme) private var colorScheme

    /// Identify-tab row tints, at full saturation; the scheme-dependent opacity
    /// is applied at render time (see `atomView`). Blue marks starred ("alert
    /// me") birds; purple marks birds you can add to your life list.
    static let starHighlight = Color(hue: 215.0 / 360.0, saturation: 0.5, brightness: 1.0)
    static let addHighlight = Color(hue: 252.0 / 360.0, saturation: 0.5, brightness: 1.0)

    /// Pill opacity: 0.35 in light mode, 0.5 in dark, so the tint stays legible
    /// against the darker background. Mirrors the photo-info panel's treatment.
    private var pillOpacity: Double { colorScheme == .dark ? 0.5 : 0.35 }

    private var uiFont: UIFont { UIFont.preferredFont(forTextStyle: textStyle) }
    private var font: Font { Font(uiFont) }
    private var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: uiFont]).width
    }

    var body: some View {
        let atoms = makeAtoms()
        FlowLayout(spacing: spaceWidth, lineSpacing: 2, alignment: alignment) {
            ForEach(Array(atoms.enumerated()), id: \.offset) { _, atom in
                atomView(atom)
            }
        }
    }

    @ViewBuilder
    private func atomView(_ atom: Atom) -> some View {
        if let background = atom.background {
            Text(atom.text)
                .font(font)
                .foregroundStyle(textColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(background.opacity(pillOpacity), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .layoutValue(key: LeadingSpaceKey.self, value: atom.leadingSpace)
        } else {
            Text(atom.text)
                .font(font)
                .foregroundStyle(textColor)
                .layoutValue(key: LeadingSpaceKey.self, value: atom.leadingSpace)
        }
    }

    // MARK: - Tokenizing

    /// A single rendered unit: a plain word or a whole highlighted phrase.
    /// `leadingSpace` records whether a space separated it from the previous
    /// atom in the original text, so punctuation glued to a phrase (e.g. the
    /// comma after "…seen before,") renders without a gap.
    private struct Atom {
        let text: String
        let background: Color?
        let leadingSpace: Bool
    }

    /// Splits the segments into atoms: plain runs become individual words (so
    /// they wrap), while each highlighted segment becomes one atomic pill.
    private func makeAtoms() -> [Atom] {
        var atoms: [Atom] = []
        // Whether a whitespace boundary precedes the next atom to be emitted.
        var pendingSpace = false
        // False until the first atom — the first atom never gets a leading gap.
        var started = false

        for segment in segments {
            if let color = segment.highlight {
                let leading = segment.text.first?.isWhitespace ?? false
                let trailing = segment.text.last?.isWhitespace ?? false
                let core = segment.text.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty else {
                    pendingSpace = pendingSpace || leading || trailing
                    continue
                }
                atoms.append(Atom(
                    text: core,
                    background: color,
                    leadingSpace: started && (pendingSpace || leading)
                ))
                started = true
                pendingSpace = trailing
            } else {
                let text = segment.text
                var index = text.startIndex
                var precededSpace = pendingSpace
                while index < text.endIndex {
                    if text[index].isWhitespace {
                        precededSpace = true
                        index = text.index(after: index)
                        continue
                    }
                    let start = index
                    while index < text.endIndex, !text[index].isWhitespace {
                        index = text.index(after: index)
                    }
                    atoms.append(Atom(
                        text: String(text[start..<index]),
                        background: nil,
                        leadingSpace: started && precededSpace
                    ))
                    started = true
                    precededSpace = false
                }
                // True only if the segment ended on whitespace.
                pendingSpace = precededSpace
            }
        }
        return atoms
    }
}

/// Per-subview flag: does a word-space precede this atom? Punctuation glued to a
/// preceding pill sets this false so the two render flush.
private nonisolated struct LeadingSpaceKey: LayoutValueKey {
    static let defaultValue = true
}

/// A left-to-right wrapping layout. Items flagged with `LeadingSpaceKey == true`
/// get a `spacing` gap before them (unless they start a line); flagged false,
/// they butt against the previous item. Lines are vertically centered so a
/// taller pill doesn't shove its plain neighbors' baselines around.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var alignment: HorizontalAlignment

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let lines = computeLines(subviews: subviews, maxWidth: maxWidth)
        let contentWidth = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +)
            + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? contentWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = proposal.width ?? .infinity
        let lines = computeLines(subviews: subviews, maxWidth: maxWidth)
        var y = bounds.minY
        for line in lines {
            let startX: CGFloat
            if alignment == .center {
                startX = bounds.minX + (bounds.width - line.width) / 2
            } else if alignment == .trailing {
                startX = bounds.maxX - line.width
            } else {
                startX = bounds.minX
            }
            var x = startX
            for (offset, index) in line.indices.enumerated() {
                let subview = subviews[index]
                let size = subview.sizeThatFits(.unspecified)
                if offset > 0, subview[LeadingSpaceKey.self] {
                    x += spacing
                }
                subview.place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width
            }
            y += line.height + lineSpacing
        }
    }

    private func computeLines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        let sizes = subviews.indices.map { subviews[$0].sizeThatFits(.unspecified) }
        // An atom with no leading space is "glued" to its predecessor (e.g. the
        // final period after "…your life list"). A glued atom must never start a
        // line on its own — that's what orphans trailing punctuation onto the next
        // line. So on overflow we carry the whole trailing glued chain down with it.
        func glued(_ i: Int) -> Bool { !subviews[i][LeadingSpaceKey.self] }
        func lineWidth(_ indices: [Int]) -> CGFloat {
            var w: CGFloat = 0
            for (offset, i) in indices.enumerated() {
                if offset > 0, !glued(i) { w += spacing }
                w += sizes[i].width
            }
            return w
        }

        var lineGroups: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0

        for index in subviews.indices {
            let gap = current.isEmpty ? 0 : (glued(index) ? 0 : spacing)
            if !current.isEmpty, currentWidth + gap + sizes[index].width > maxWidth {
                if glued(index) {
                    // Walk back to the start of the trailing glued chain (the first
                    // atom that *does* have a leading space), and move that whole run
                    // down with the overflowing atom — unless it's the only thing on
                    // the line, in which case there's nothing better to do.
                    var start = current.count - 1
                    while start > 0, glued(current[start]) { start -= 1 }
                    if start > 0 {
                        let chain = Array(current[start...])
                        current.removeSubrange(start...)
                        lineGroups.append(current)
                        current = chain + [index]
                        currentWidth = lineWidth(current)
                        continue
                    }
                }
                lineGroups.append(current)
                current = [index]
                currentWidth = sizes[index].width
            } else {
                current.append(index)
                currentWidth += gap + sizes[index].width
            }
        }
        if !current.isEmpty { lineGroups.append(current) }

        return lineGroups.map { indices in
            var line = Line()
            line.indices = indices
            line.width = lineWidth(indices)
            line.height = indices.map { sizes[$0].height }.max() ?? 0
            return line
        }
    }
}
