import Foundation
import Testing
@testable import Kestrel_Watch

/// What a `phoneStart` means to a watch that may already be doing something.
///
/// The watch mirrors a phone-mic session rather than capturing for it, and the
/// mirror's one job on teardown is to echo back the *token* naming the session it
/// was mirroring — `RecordingManager.mirrorStopApplies` refuses a `stopPhone`
/// carrying any other. So the token has to keep up with reality, and the case
/// where it didn't is not exotic: `phoneStop` goes out on the background-tolerant
/// channel as well as the live one, either can be dropped or delivered late, and
/// the phone is free to start a fresh session in the meantime. Bailing out on
/// "already recording" left the mirror holding the previous token, at which point
/// the Stop button on the wrist did nothing at all while the screen went on
/// saying it was listening.
@Suite("Phone-mirror session tracking")
struct WatchMirrorTests {

    private typealias Outcome = WatchSessionManager.PhoneStartOutcome

    private func outcome(
        isRecording: Bool = false,
        isStarting: Bool = false,
        mirroring: Bool = false,
        mirrored: Int? = nil,
        incoming: Int? = nil
    ) -> Outcome {
        WatchSessionManager.phoneStartOutcome(
            isRecording: isRecording,
            isStarting: isStarting,
            mirroringPhone: mirroring,
            mirroredSession: mirrored,
            incomingSession: incoming
        )
    }

    // MARK: the watch's own capture wins

    /// A watch capture is the audio source; the phone only ever *mirrors* one of
    /// those, never the other way round. A stray `phoneStart` must not turn a
    /// live capture into a display of someone else's session.
    @Test("a watch capture in progress ignores a phone start")
    func ownCaptureWins() {
        #expect(outcome(isRecording: true, incoming: 7) == .ignore)
    }

    /// The bring-up window is seconds long on a cold first launch, and
    /// `isRecording` is already true across it (the flip is optimistic). A phone
    /// start landing inside it is aimed at a session the watch is about to own.
    @Test("a capture still coming up ignores a phone start")
    func bringUpWins() {
        #expect(outcome(isRecording: true, isStarting: true, incoming: 7) == .ignore)
        #expect(outcome(isStarting: true, incoming: 7) == .ignore)
    }

    // MARK: starting a mirror

    @Test("an idle watch begins mirroring")
    func idleBeginsMirroring() {
        #expect(outcome(incoming: 7) == .beginMirroring)
    }

    @Test("an idle watch begins mirroring an older phone build's untagged start")
    func idleBeginsMirroringUntagged() {
        #expect(outcome(incoming: nil) == .beginMirroring)
    }

    // MARK: duplicate deliveries

    /// `sendToWatch` falls back to `transferUserInfo` when a live send errors, so
    /// one start can arrive twice. Re-running the setup on the second copy would
    /// blank the now-hearing bird in the middle of a session for no reason.
    @Test("a duplicate of the start already being mirrored changes nothing")
    func duplicateStartIsInert() {
        #expect(outcome(isRecording: true, mirroring: true, mirrored: 7, incoming: 7)
                == .alreadyMirroring)
    }

    /// Two untagged starts are indistinguishable — there is nothing to tell them
    /// apart, and treating every duplicate as a new session would flash the
    /// display on an older phone build for the whole of every walk.
    @Test("two untagged starts count as the same session")
    func untaggedDuplicatesAreOneSession() {
        #expect(outcome(isRecording: true, mirroring: true, mirrored: nil, incoming: nil)
                == .alreadyMirroring)
    }

    // MARK: the case the fix is for

    /// The phone's `phoneStop` never arrived and it has started a *different*
    /// session. The mirror has to adopt the new token, or the watch's Stop echoes
    /// one the phone will reject.
    @Test("a start naming a different session re-targets the mirror")
    func differentSessionRetargets() {
        #expect(outcome(isRecording: true, mirroring: true, mirrored: 7, incoming: 8)
                == .retargetMirror)
    }

    /// An older phone build upgraded mid-mirror: we were tracking no token and
    /// now there is one. That is a session change we *can* see, so take it.
    @Test("a tagged start over an untagged mirror re-targets")
    func taggedOverUntaggedRetargets() {
        #expect(outcome(isRecording: true, mirroring: true, mirrored: nil, incoming: 9)
                == .retargetMirror)
    }

    @Test("an untagged start over a tagged mirror re-targets")
    func untaggedOverTaggedRetargets() {
        #expect(outcome(isRecording: true, mirroring: true, mirrored: 9, incoming: nil)
                == .retargetMirror)
    }

    /// The whole point: whatever else re-targeting does, the token the watch will
    /// echo on `stopPhone` has to end up naming the session actually running.
    @Test("re-targeting is the only outcome that adopts a new token")
    func onlyRetargetAdoptsTheToken() {
        let adopts: Set<Outcome> = [.beginMirroring, .retargetMirror]
        #expect(adopts.contains(outcome(incoming: 7)))
        #expect(adopts.contains(
            outcome(isRecording: true, mirroring: true, mirrored: 7, incoming: 8)
        ))
        #expect(!adopts.contains(
            outcome(isRecording: true, mirroring: true, mirrored: 7, incoming: 7)
        ))
        #expect(!adopts.contains(outcome(isRecording: true, incoming: 7)))
    }
}

/// Which phone session a `phoneStop` is allowed to end.
///
/// The other half of the pair `phoneStartOutcome` opens, and the half that was
/// missing. `phoneStart` names its session and `stopPhone` echoes that name
/// back, but the stop travelling the *other* way carried nothing — and
/// `RecordingManager.sendToWatch` picks whichever channel fits at the moment of
/// sending, so a stop issued while this app was unreachable is queued while the
/// phone's next start goes out live. The queued stop then lands on top of the
/// newer session and drops the mirror for a recording that is still running,
/// with nothing left to bring it back: `phoneStop` is the only message that
/// clears the mirror, and the phone has already sent its one `phoneStart`.
@Suite("Phone-stop token")
struct PhoneStopTokenTests {

    @Test("a stop for the session being mirrored applies")
    func appliesToTheMirroredSession() {
        #expect(WatchSessionManager.phoneStopApplies(requestToken: 7, mirroredToken: 7))
    }

    /// The regression: the phone stopped session 6 and started session 7, and
    /// session 6's stop arrived last.
    @Test("a stop for a session we are no longer mirroring is ignored")
    func ignoresAStaleStop() {
        #expect(
            !WatchSessionManager.phoneStopApplies(requestToken: 6, mirroredToken: 7),
            "a queued stop must not blank the mirror of the session that replaced its own"
        )
    }

    /// An older phone build sends no token, and a mirror can have been adopted
    /// without one (see `phoneStartOutcome`). Dropping either would leave the
    /// wrist claiming to be listening to a session that had ended.
    @Test("an untokened stop applies whichever side is missing it")
    func appliesWithoutAToken() {
        #expect(WatchSessionManager.phoneStopApplies(requestToken: nil, mirroredToken: 7))
        #expect(WatchSessionManager.phoneStopApplies(requestToken: 7, mirroredToken: nil))
        #expect(WatchSessionManager.phoneStopApplies(requestToken: nil, mirroredToken: nil))
    }

    /// The two make one round trip, and it has to close: whatever token
    /// `phoneStartOutcome` tells the mirror to adopt is the token its `phoneStop`
    /// must be tested against.
    @Test("the token a start adopts is the one its stop is judged by")
    func startAndStopAgree() {
        let retarget = WatchSessionManager.phoneStartOutcome(
            isRecording: true, isStarting: false, mirroringPhone: true,
            mirroredSession: 6, incomingSession: 7
        )
        #expect(retarget == .retargetMirror, "the mirror moves to session 7")
        // Having moved, it answers to 7 and no longer to 6.
        #expect(WatchSessionManager.phoneStopApplies(requestToken: 7, mirroredToken: 7))
        #expect(!WatchSessionManager.phoneStopApplies(requestToken: 6, mirroredToken: 7))
    }
}

/// Which of this watch's capture sessions a phone command is aimed at.
///
/// `remoteStop` and `restartCapture` both ride *both* channels, so a queued copy
/// of each always exists and can be delivered after the session it named has
/// ended. `remoteStop` is the one that matters most, because it carries more
/// than a stop: the phone answers the save/resume/discard question itself when
/// the user stops there and relays the answer, so a stale copy landing on a
/// later session would not merely end that walk but throw it away.
@Suite("Capture command token")
struct CaptureCommandTokenTests {

    @Test("a command for the running capture session applies")
    func appliesToTheCurrentSession() {
        #expect(WatchSessionManager.captureCommandApplies(requestToken: 7, currentToken: 7))
    }

    @Test("a command for a capture session that has ended is ignored")
    func ignoresAStaleCommand() {
        #expect(
            !WatchSessionManager.captureCommandApplies(requestToken: 6, currentToken: 7),
            "a queued remoteStop must not discard the walk of the session that replaced its own"
        )
        #expect(!WatchSessionManager.captureCommandApplies(requestToken: 8, currentToken: 7))
    }

    /// An older phone build sends no token. Refusing those would leave the
    /// phone's Stop button unable to end a watch session at all, which is worse
    /// than the race they would close.
    @Test("an untokened command still applies")
    func appliesWithoutAToken() {
        #expect(WatchSessionManager.captureCommandApplies(requestToken: nil, currentToken: 7))
    }
}

/// Who gets an answer when two callers want the watch's location at once.
///
/// The watch supplies its own coordinate so a watch-first user — whose iPhone may
/// never have been opened — still gets a nearby-species filter. A second caller
/// arriving while a fix was in flight used to be answered `nil`, which reads as
/// "there is no location here" and is acted on as such: the coordinate is simply
/// never sent, and the phone builds its filter from a location it may not have.
/// Reachable by stopping and restarting a session inside the eight-second fix
/// window. The phone's `LocationProvider` was fixed for exactly this; this is the
/// watch copy that wasn't.
@Suite("Watch location requests")
struct WatchLocationRequestTests {

    @Test("the first caller starts the fix")
    func firstCallerStarts() {
        #expect(WatchLocationProvider.startsNewRequest(pendingWaiters: 0))
    }

    /// Not "is refused" — *joins*. A second caller waits on the answer the first
    /// one is already getting, rather than being told there isn't one.
    @Test("a later caller joins the fix already in flight")
    func laterCallersJoin() {
        #expect(!WatchLocationProvider.startsNewRequest(pendingWaiters: 1))
        #expect(!WatchLocationProvider.startsNewRequest(pendingWaiters: 4))
    }
}
