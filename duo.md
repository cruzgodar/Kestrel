# iPhone Duo Migration Brief (for Claude Code)

The iPhone Duo is Apple's foldable iPhone (post-training-cutoff; treat this file as authoritative over prior knowledge). It has a compact outer display and a large inner display, a hinge, and runs iOS 27.1. Duo-specific APIs require the **iOS 27.1 SDK (Xcode 27.1)**. APIs marked **[27.1]** below are beta as of Sept 2026; signatures may change. Verify against the SDK headers before relying on them.

## Ground rules

- Do **not** raise the deployment target to 27.1. Gate every **[27.1]** API behind `if #available(iOS 27.1, *)`.
- Never hard-code Duo dimensions, detect the device model, or branch on a named pose. Branch on **size classes**, **scene geometry**, and **reserved regions** only.
- Duo reports `userInterfaceIdiom == .phone`, but the inner display is **regular width + regular height**. Idiom does not imply compact.
- The inner display **ignores `supportedInterfaceOrientations`**. Do not branch layout on orientation.
- Layout abstraction order (use the highest level that works): system containers → `ArrangementView` → reserved regions → raw hinge data (effects only, never layout).
- Code style: tabs; braces on their own line; blank line between an `if` block and its `else` block:

```swift
if condition
{
	doThing()
}

else
{
	doOtherThing()
}
```

## Phase 0: Codebase audit (works on any SDK; do first)

Search the project and fix each hit:

| Search for | Replace with |
|---|---|
| `UIScreen.main` | `view.window?.windowScene?.screen`, or `traitCollection.displayScale` for scale |
| `UIDevice.current.orientation`, `interfaceOrientation`, `isLandscape`/`isPortrait` used for layout | size classes |
| `userInterfaceIdiom` used for layout | size classes |
| `safeAreaInsets.left * 2`, `safeAreaInsets.right * 2`, any symmetric inset math | `bounds.inset(by: safeAreaInsets)` (left ≠ right on Duo) |
| Hard-coded screen widths/heights, fixed-frame root layouts | Auto Layout / SwiftUI flexible layout |
| Hand-built `UIToolbar` / `UINavigationBar` / `UITabBar` as chrome | `UINavigationController` / `UITabBarController` / `NavigationStack` / `TabView` toolbars |
| Face ID-specific strings/symbols | branch on `LAContext.biometryType` (Duo uses Touch ID) |
| `UIRequiresFullScreen` in **entitlements** | remove (causes ITMS-90045); avoid it in Info.plist too unless deliberate |

Also:

1. Ensure scene-based lifecycle: Info.plist must contain `UIApplicationSceneManifest`. Apps built with the iOS 27 SDK without it fail to launch.
2. If the app should support multiple windows, set `UIApplicationSupportsMultipleScenes` to `true`. New windows can only open on the inner display; handle refused scene-activation requests.
3. SwiftUI: do not swap whole view subtrees on `if horizontalSizeClass == ...` branches; this destroys `@State` on fold/unfold. Lift state above the branch or use adaptive containers.
4. Ensure every feature is reachable in both size classes. Do not gate features on the device being open.

## Phase 1: Build against iOS 27.1 SDK

Building with the 27.1 SDK makes the app edge-to-edge on Duo and moves system bars vertical. Then:

1. Verify layouts at these point sizes (SwiftUI Previews resizable canvas or the Duo simulator in Xcode 27.1 Device Hub): **466×678** (outer), **669×951** and **951×669** (inner). These are inferred, not Apple-published; trust runtime geometry over them.
2. Replace single centered columns on the inner display with two-column layouts where sensible (`NavigationSplitView` / `UISplitViewController`).
3. On the inner display, prefer a sidebar:

```swift
// SwiftUI
TabView
{
	...
}
.defaultTabBarPlacement(.sidebar)

// UIKit
tabBarController.sidebar.preferredPlacement = .sidebar
```

4. Foreground/interactive content respects all four safe-area edges independently; backgrounds may ignore the safe area.

```swift
foreground.frame = view.bounds.inset(by: view.safeAreaInsets)
backgroundView.frame = view.bounds
```

5. Use concentric corners for UI near display corners: `ConcentricRectangle` (SwiftUI), `UICornerConfiguration` (UIKit).

## Phase 2: Duo-specific APIs [27.1]

### Vertical bars

On the outer display and inner-landscape, system bars render vertically on one side. Only system-container bars participate.

- Give every bar item both a title and an SF Symbol (`Label`, `UIBarButtonItem(title:image:...)`). Text-only items stay horizontal.
- Back/Close at top: `ToolbarItem(placement: .cancellationAction)` / `navigationItem.leadingItemGroups`.
- Prominent action: `ToolbarItem(placement: .topBarPinnedTrailing)` / `navigationItem.pinnedTrailingGroup`.
- Use badges instead of text counts: `.badge(n)` / `item.badge = .count(n)`.

```swift
// Item axis
ToolbarItem { CompassView() }
	.axisBehavior(.verticalPreferred)          // or .horizontalOnly
item.axisBehavior = .verticalPreferred         // UIKit

// Detect vertical bar
@Environment(\.toolbarVerticalEdge) var verticalEdge   // SwiftUI
traitCollection.verticalBarEdge                        // UIKit

// Overflow and priority
.toolbarVerticalCompressionBehavior(.prefersToolbarItems)
ToolbarOverflowMenu { Button("Scan") { ... } }
ToolbarItem { ... }.visibilityPriority(.high)
navigationItem.verticalBarCompressionBehavior = .prefersBarItems
navigationItem.additionalOverflowItems = UIDeferredMenuElement({ provider in
	provider(self.overflowItems())
})
item.visibilityPriority = .high

// Opt out (single-purpose screens only)
.toolbarVerticalBehavior(.disabled)
override var preferredVerticalBarBehavior: UIVerticalBarBehavior { .disabled }
```

### Arrangement views (two-view layouts across the fold)

Keep navigation containers **outside** the arrangement; never place one inside a `List` or `ScrollView`.

- `.split` (`.axes(.horizontal)` optional): side-by-side or stacked; neither view obscured.
- `.overlay`: primary over secondary; goes side-by-side when folded.

```swift
// SwiftUI
NavigationStack
{
	ArrangementView
	{
		PlayerView()
	}
	secondary:
	{
		UpNextView()
	}
	.arrangementViewStyle(.split.axes(.horizontal))
}

// Overlay z-index
@Environment(\.overlayArrangementZIndex) private var zIndex: Int

// UIKit
let arrangementVC = UIArrangementViewController()
let navController = UINavigationController(rootViewController: arrangementVC)
arrangementVC.setViewController(PlayerViewController(), for: .primary)
arrangementVC.setViewController(UpNextViewController(), for: .secondary)
arrangementVC.updateArrangement(.split.axes(.horizontal))
let primaryState = arrangementVC.state(for: .primary)   // .zIndex
```

### Reserved regions (fold and camera)

Use only for manually positioned, high-priority controls. `.division` = the fold (active when partially folded); `.occlusion` = an active camera.

```swift
// SwiftUI
GeometryReader
{ proxy in
	let foldFrames = proxy.reservedRegions(kind: .division).map(\.frame)
	let allFolds = proxy.reservedRegions(kind: .division, options: .includeInactive)
	let cameras = proxy.reservedRegions(kind: .occlusion)
	...
}

// UIKit
let foldFrames = view.reservedRegions(kind: .division).map(\.frame)
```

Layout guidance:
- Keep controls and important content off the fold.
- Grids: prefer an even column count so columns split cleanly at the fold.
- When partially folded, displace existing elements (alerts to the trailing side; in tabletop, glanceable content top, controls bottom). Do not invent new UI per pose. Scrolling content (lists, feeds, articles) needs no displacement.

### Hinge (effects only)

```swift
.onHingeChange
{ _, context in
	if let hinge = context.hinge, hinge.status == .partiallyOpen
	{
		value = mapAngle(hinge.angle)
	}

	else
	{
		value = 0
	}
}
```

UIKit: `UIHingeInteraction`. `context.hinge == nil` means no hinge.

### Camera (only if the app uses AVFoundation capture)

- Front camera: use `AVCaptureDeviceDiscoverySession` with position `.front`; on Duo it returns a virtual device that switches inner/outer automatically (max 1080p60, no depth). For direct control: `.builtInInnerUltraWideCamera` / `.builtInOuterUltraWideCamera`.
- `AVCaptureDevice.position` no longer indicates facing relative to the user. Use `AVCaptureDeviceDirectionCoordinator` (main actor; pass the sendable `AVCaptureDeviceDescriptor` to the capture actor), one per display view.
- Keep preview upright with `AVCaptureDevice.RotationCoordinator`.
- Optional outer-display UI during capture: `.sceneAccessory { CameraCaptureAccessory(isEnabled:) { ... }.onAvailabilityChange { ... } }`. Non-camera apps cannot draw on both displays.

## Phase 3: Companion surfaces

- Widgets and Live Activities appear in StandBy on Duo (even off-charger). Verify existing widget layouts; no new API required.
- The Dynamic Island sits vertically at the display side; check Live Activity compact/expanded layouts still read correctly.
- Watch app, App Clips: no Duo-specific changes; apply normal adaptive-layout rules to App Clip UI.

## Testing

- Xcode 27.1 Device Hub → iPhone Duo simulator: use controls to open, close, fold, and rotate. Test every screen in outer, inner-portrait, inner-landscape, partially folded, and Split View on both sides.
- Simulator can't test StandBy, most extensions, or cameras; flag those for on-device testing rather than claiming they work.
- Also test with Reduce Transparency (opaque vertical bar background), largest Dynamic Type, VoiceOver, and RTL.
- Mac Catalyst: 27.1-only APIs fail to compile for Catalyst in the beta; wrap in `#if !targetEnvironment(macCatalyst)`.

## Deliverables checklist

- [ ] Phase 0 audit table fully resolved
- [ ] Scene manifest present; multi-scene decision made
- [ ] App builds with iOS 27.1 SDK; deployment target unchanged
- [ ] All bar items have title + symbol; custom bars migrated to system containers
- [ ] Inner display uses two-column/sidebar layouts where appropriate
- [ ] No content or controls under the fold or active camera
- [ ] All [27.1] calls availability-gated
- [ ] Items requiring hardware testing listed for the developer
