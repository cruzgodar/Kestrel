import SwiftUI

/// Whether the view is on a foldable's **inner** display — the one you get by
/// opening the phone — and the layouts that answer to it.
///
/// The fold itself is what tells them apart, not size classes: those say how
/// much room there is, not which display it is, and the outer display is wide
/// enough to report regular width, so keying "open" off `horizontalSizeClass`
/// hands the closed phone layouts meant for the open one. A division region is
/// the fold, so it is present on the inner display and nowhere else — not on the
/// outer display, not on any phone.
///
/// `.includeInactive` matters: a fold only counts as *active* while the device
/// is partway shut, and a phone opened flat would otherwise look like a phone.
enum InnerDisplay {
    /// Reads the fold off a geometry proxy. Always false below iOS 27.1, which
    /// is where reserved regions arrive — and where foldables do.
    static func contains(_ proxy: GeometryProxy) -> Bool {
        guard #available(iOS 27.1, *) else { return false }
        return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
    }
}

extension View {
    /// Reports whether this view is on a foldable's inner display, now and
    /// whenever that changes.
    func onInnerDisplayChange(_ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { InnerDisplay.contains($0) } action: { action($0) }
    }
}
