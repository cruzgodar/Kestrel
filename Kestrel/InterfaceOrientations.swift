import SwiftUI
import UIKit

/// Which ways up the app may turn: portrait, except in a window that is showing
/// the full-screen species viewer, which may also turn to landscape.
///
/// `Info.plist` lists landscape for iPhone, or the system would never rotate
/// at all; the app delegate narrows that back to portrait window by window
/// (`AppDelegate.application(_:supportedInterfaceOrientationsFor:)`). The
/// viewer opts its window in with `.allowsLandscape()`. Nothing else does —
/// not even `HalfScreenSpeciesView`, which is the same viewer standing in a
/// pane of the Identify tab.
enum InterfaceOrientations {
    /// Windows currently allowed landscape, counted, in case one viewer is
    /// ever stacked over another.
    private static var landscapeWindows: [ObjectIdentifier: Int] = [:]

    static func mask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let window, landscapeWindows[ObjectIdentifier(window)] != nil else {
            return .portrait
        }
        return [.portrait, .landscape]
    }

    fileprivate static func allowLandscape(in window: UIWindow) {
        landscapeWindows[ObjectIdentifier(window), default: 0] += 1
        refresh(window)
    }

    fileprivate static func revokeLandscape(in window: UIWindow) {
        let id = ObjectIdentifier(window)
        guard let count = landscapeWindows[id] else { return }
        landscapeWindows[id] = count > 1 ? count - 1 : nil
        refresh(window)
        // Turning back is not left to `setNeedsUpdate…` alone: ask for portrait
        // outright, so a viewer closed sideways hands back an upright app.
        if landscapeWindows[id] == nil {
            window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }

    /// Has the window ask again, which turns it straight away when the phone
    /// is already held in an orientation that has just become allowed.
    private static func refresh(_ window: UIWindow) {
        var controller = window.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        InterfaceOrientations.mask(for: window)
    }
}

extension View {
    /// Lets the window this view is in turn to landscape for as long as the
    /// view is in it.
    func allowsLandscape() -> some View {
        background(LandscapeAllowance().allowsHitTesting(false))
    }
}

private struct LandscapeAllowance: UIViewRepresentable {
    func makeUIView(context: Context) -> AllowanceView { AllowanceView() }
    func updateUIView(_ uiView: AllowanceView, context: Context) {}

    final class AllowanceView: UIView {
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            guard newWindow !== window else { return }
            if let window { InterfaceOrientations.revokeLandscape(in: window) }
            if let newWindow { InterfaceOrientations.allowLandscape(in: newWindow) }
        }
    }
}
