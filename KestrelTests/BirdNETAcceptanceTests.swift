import Foundation
import Testing
@testable import Kestrel

/// Which of BirdNET's 6,522 label scores become detections.
///
/// Two independent rules, and the whole point of this suite is that they are
/// independent. Non-species classes — human voice, a dog, an engine — are
/// excluded structurally, before any threshold is consulted. The soft range
/// filter then asks an out-of-range *species* for more acoustic evidence than an
/// in-range one, rather than dropping it.
///
/// The exclusion used to be argued as a consequence of the range filter: those
/// labels sit outside every filter, and `outOfRangeThreshold` is 1.0, which was
/// described as unreachable. It isn't — the sigmoid saturates to exactly 1.0 in
/// `Float` — so that argument never held, and a loud enough engine would have
/// been reported as a bird. `accepts` refuses them without reference to any
/// threshold, and these tests are what say so.
///
/// Driven through the extracted rule rather than through `classify`, which needs
/// an ORT session and three seconds of audio that happens to produce the case
/// under test.
@Suite("BirdNET detection acceptance")
struct BirdNETAcceptanceTests {

    private let inRangeBar = BirdNETClassifier.detectionThreshold
    private let outOfRangeBar = BirdNETClassifier.outOfRangeThreshold

    // MARK: the premise the old reasoning got wrong

    /// The sigmoid saturates. Past a logit of about 17, `expf(-logit)` underflows
    /// far enough that the quotient rounds to exactly 1.0 in `Float` — so a bar
    /// of 1.0 compared with `>=` is a very high bar, not an unreachable one.
    @Test("the sigmoid reaches exactly 1.0 for a confident logit")
    func sigmoidSaturates() {
        #expect(BirdNETClassifier.confidence(logit: 20) == 1.0)
        #expect(BirdNETClassifier.confidence(logit: 0) == 0.5)
        #expect(BirdNETClassifier.confidence(logit: -20) < 0.001)
    }

    // MARK: non-species classes

    /// The case the old reasoning left open: a saturating score on a non-bird
    /// class. Nothing about a threshold saves this — only the guard does.
    @Test("a non-species class is refused even at total confidence")
    func nonBirdRefusedAtSaturation() {
        #expect(!BirdNETClassifier.accepts(
            confidence: 1.0, isNonBird: true, inRange: false
        ))
        #expect(!BirdNETClassifier.accepts(
            confidence: 1.0, isNonBird: true, inRange: true
        ))
    }

    /// And it holds however the bar is set — including the setting the doc offers
    /// for disabling the soft filter entirely, which is exactly when leaning on
    /// the range filter would have let noise through.
    @Test("a non-species class is refused at every threshold setting")
    func nonBirdRefusedAtAnyThreshold() {
        for bar: Float in [0, inRangeBar, 0.5, 1.0] {
            #expect(!BirdNETClassifier.accepts(
                confidence: 1.0, isNonBird: true, inRange: false, outOfRangeThreshold: bar
            ), "bar \(bar) must not be what keeps noise out")
        }
    }

    // MARK: the soft range filter

    @Test("an in-range species clears the ordinary bar")
    func inRangeUsesTheOrdinaryBar() {
        #expect(BirdNETClassifier.accepts(
            confidence: inRangeBar, isNonBird: false, inRange: true
        ))
        #expect(!BirdNETClassifier.accepts(
            confidence: inRangeBar.nextDown, isNonBird: false, inRange: true
        ))
    }

    /// Soft, not hard: an out-of-range species the model is completely certain
    /// about still gets through, which is the "a clear song still gets through"
    /// half of what the filter is for. This is the behavior the 1.0 bar actually
    /// has, stated rather than assumed away.
    @Test("an out-of-range species is accepted only at total confidence")
    func outOfRangeNeedsSaturation() {
        #expect(BirdNETClassifier.accepts(
            confidence: BirdNETClassifier.confidence(logit: 20),
            isNonBird: false,
            inRange: false
        ), "a saturating score clears the 1.0 bar")
        #expect(!BirdNETClassifier.accepts(
            confidence: 0.99, isNonBird: false, inRange: false
        ), "and a merely strong one does not")
    }

    /// The bar is a knob, and it moves the out-of-range case only. Setting it
    /// equal to `detectionThreshold` disables the soft filter, as documented.
    @Test("lowering the bar to the ordinary threshold disables the soft filter")
    func loweringTheBarDisablesTheFilter() {
        #expect(BirdNETClassifier.accepts(
            confidence: inRangeBar,
            isNonBird: false,
            inRange: false,
            outOfRangeThreshold: inRangeBar
        ))
    }

    /// Raising the bar must not disturb an in-range detection — the two branches
    /// share nothing but the comparison.
    @Test("the out-of-range bar leaves in-range detections alone")
    func theBarDoesNotAffectInRange() {
        #expect(BirdNETClassifier.accepts(
            confidence: inRangeBar,
            isNonBird: false,
            inRange: true,
            outOfRangeThreshold: 1.0
        ))
    }

    // MARK: the label set the guard is built from

    /// The guard resolves `nonBirdLabels` to indices once at load, so the names
    /// have to match the label file's scientific column exactly. A typo here is
    /// silent: the class simply stops being excluded.
    @Test("every non-bird label exists in the shipped catalog")
    func nonBirdLabelsAreRealLabels() {
        let catalog = Set(SpeciesCatalog.shared.all.map(\.scientificName))
        // The catalog loads from the bundle; if it's empty the check below would
        // pass vacuously, so say what happened instead.
        #expect(!catalog.isEmpty, "the BirdNET label file should be in the test host's bundle")
        for label in BirdNETClassifier.nonBirdLabels {
            #expect(catalog.contains(label), "\(label) is not a label BirdNET emits")
        }
    }
}
