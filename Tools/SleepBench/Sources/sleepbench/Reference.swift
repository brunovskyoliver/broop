import Foundation

// Reference.swift — score NOOP nights against an EXTERNAL hypnogram (`--reference <csv>`).
//
// The CSV is `start,end,stage` (unix seconds, a header row is optional), one row per hypnogram segment, e.g.
// an Apple Watch export or a hand-scored PSG. Every function here is a pure function over segment arrays, so
// the scoring is unit-tested with no database and no health data (`ReferenceScoringTests`).
//
// EVALUATION DOMAIN (VALIDATION_PROTOCOL R1). Each night is scored on ONE 30 s grid that runs from the
// earlier of the two hypnograms' first segment to the later of their last segment. An epoch neither hypnogram
// covers is wake on that side: outside a recorded night nobody is asleep. So a session NOOP ends 70 minutes
// after the reference counts 70 minutes of sleep-vs-wake disagreement, instead of falling outside the
// comparison. This is a whole-night domain, not SleepBench section C's in-session one, and the two kappas are
// not comparable.
//
// A consumer device is not ground truth (R8). These numbers say how far NOOP sits from one other estimate.

/// One reference segment with its stage normalised to the closed set `ReferenceStage` describes.
struct RefSegment: Equatable {
    let start: Int
    let end: Int
    let stage: String
}

/// The reference vocabulary after normalisation.
///
/// `sleep` is asleep with no stage (Apple's "asleep" / "asleepUnspecified"): it counts toward total sleep and
/// the sleep/wake comparison, and is left out of the 4-class comparison. `inbed` is a container, not a stage:
/// it only labels an epoch no staged segment covers, and then reads as wake (in bed, not asleep).
enum ReferenceStage {
    static let stagedClasses = ["wake", "light", "deep", "rem"]
    static let unstagedSleep = "sleep"
    static let inBed = "inbed"

    /// Map an input stage string onto the closed set, or nil when it is not one this tool knows. Unknown
    /// strings are an error at parse time rather than a silent guess.
    static func normalise(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "wake", "awake": return "wake"
        case "light", "core", "n1", "n2": return "light"
        case "deep", "n3", "sws": return "deep"
        case "rem", "r": return "rem"
        case "asleep", "sleep", "asleepunspecified", "unspecified": return unstagedSleep
        case "inbed", "in_bed", "in bed": return inBed
        default: return nil
        }
    }

    static func isSleep(_ label: String) -> Bool { label != "wake" }
}

struct ReferenceParseError: Error, CustomStringConvertible {
    let description: String
}

/// Parse a `start,end,stage` CSV. Seconds may carry a fractional part (it is truncated). A first line whose
/// first field is not a number is taken as a header. Blank lines are skipped. Rows with `end <= start` are
/// rejected, as is any stage outside `ReferenceStage.normalise`.
func parseReferenceCSV(_ text: String) throws -> [RefSegment] {
    var out: [RefSegment] = []
    for (i, line) in text.split(whereSeparator: \.isNewline).enumerated() {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if fields.allSatisfy({ $0.isEmpty }) { continue }
        guard fields.count >= 3 else {
            throw ReferenceParseError(description: "line \(i + 1): expected start,end,stage")
        }
        guard let s = Double(fields[0]), let e = Double(fields[1]) else {
            if i == 0 { continue }   // header
            throw ReferenceParseError(description: "line \(i + 1): start/end must be unix seconds")
        }
        guard let stage = ReferenceStage.normalise(fields[2]) else {
            throw ReferenceParseError(description: "line \(i + 1): unknown stage '\(fields[2])'")
        }
        let start = Int(s), end = Int(e)
        guard end > start else {
            throw ReferenceParseError(description: "line \(i + 1): end must be after start")
        }
        out.append(RefSegment(start: start, end: end, stage: stage))
    }
    return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
}

/// Split reference segments into nights: a new night starts wherever the gap since the latest end seen so far
/// is at least `gapSeconds`. Only segments that are sleep, or wake inside a night, define the span; `inbed`
/// segments are kept with whichever night they overlap but never start one on their own.
func groupReferenceNights(_ segs: [RefSegment], gapSeconds: Int = 3 * 3600) -> [[RefSegment]] {
    let staged = segs.filter { $0.stage != ReferenceStage.inBed }.sorted { $0.start < $1.start }
    var nights: [[RefSegment]] = []
    var curEnd = Int.min
    for s in staged {
        if nights.isEmpty || s.start - curEnd >= gapSeconds {
            nights.append([s]); curEnd = s.end
        } else {
            nights[nights.count - 1].append(s); curEnd = max(curEnd, s.end)
        }
    }
    // Attach in-bed containers to the night they overlap (they only fill epochs nothing else labels).
    for b in segs where b.stage == ReferenceStage.inBed {
        if let k = nights.firstIndex(where: { n in n.contains { $0.start < b.end && b.start < $0.end } }) {
            nights[k].append(b)
        }
    }
    return nights
}

/// Label a 30 s grid starting at `gridStart` with `n` epochs from `segments` (any stage strings), taking each
/// epoch's label from the segment covering its START instant. A staged segment beats an `inbed` one; an
/// `inbed`-only epoch is wake; an uncovered epoch is `fill`.
func labelsOnGrid(_ segments: [(start: Int, end: Int, stage: String)], gridStart: Int, n: Int,
                  fill: String = "wake") -> [String] {
    var out = [String](repeating: fill, count: max(0, n))
    var inBedOnly = [Bool](repeating: false, count: max(0, n))
    let step = Int(epochSeconds)
    for seg in segments {
        guard seg.end > seg.start else { continue }
        // First epoch whose start instant is >= seg.start, last whose start instant is < seg.end.
        let lo = max(0, Int(ceil(Double(seg.start - gridStart) / Double(step))))
        let hi = min(n - 1, Int(ceil(Double(seg.end - gridStart) / Double(step))) - 1)
        guard lo <= hi else { continue }
        for i in lo...hi {
            if seg.stage == ReferenceStage.inBed {
                if out[i] == fill && !inBedOnly[i] { inBedOnly[i] = true }
            } else {
                out[i] = seg.stage
                inBedOnly[i] = false
            }
        }
    }
    for i in 0..<out.count where inBedOnly[i] { out[i] = "wake" }
    return out
}

/// One night's comparison, everything in minutes on the shared 30 s grid.
struct NightScore {
    let refOnset: Double?, predOnset: Double?      // minutes from grid start to the first sleep epoch
    let refOffset: Double?, predOffset: Double?    // minutes from grid start to the END of the last sleep epoch
    let refTST: Double, predTST: Double
    let refStageMin: [String: Double]              // wake/light/deep/rem/sleep
    let predStageMin: [String: Double]
    let stage4: Confusion                          // epochs where the reference carries a stage
    let sleepWake: Confusion                       // every epoch on the grid
    var onsetErr: Double? { refOnset.flatMap { r in predOnset.map { $0 - r } } }
    var offsetErr: Double? { refOffset.flatMap { r in predOffset.map { $0 - r } } }
    var tstErr: Double { predTST - refTST }
}

/// Score one night. `ref` and `pred` must already be on the same grid (same start, same length).
func scoreNight(ref: [String], pred: [String]) -> NightScore {
    let n = min(ref.count, pred.count)
    let r = Array(ref.prefix(n)), p = Array(pred.prefix(n))
    let toMin = epochSeconds / 60.0
    func onset(_ l: [String]) -> Double? { l.firstIndex(where: ReferenceStage.isSleep).map { Double($0) * toMin } }
    func offset(_ l: [String]) -> Double? { l.lastIndex(where: ReferenceStage.isSleep).map { Double($0 + 1) * toMin } }
    func minutes(_ l: [String]) -> [String: Double] {
        var m = [String: Double](uniqueKeysWithValues: (ReferenceStage.stagedClasses + [ReferenceStage.unstagedSleep]).map { ($0, 0.0) })
        for x in l { m[x, default: 0] += toMin }
        return m
    }
    var c4 = Confusion(classes: stageOrder)
    var c2 = Confusion(classes: ["wake", "sleep"])
    for i in 0..<n {
        let pr = p[i] == ReferenceStage.unstagedSleep ? "light" : p[i]
        c2.add(ref: ReferenceStage.isSleep(r[i]) ? "sleep" : "wake", pred: ReferenceStage.isSleep(pr) ? "sleep" : "wake")
        if r[i] != ReferenceStage.unstagedSleep { c4.add(ref: r[i], pred: pr) }
    }
    return NightScore(refOnset: onset(r), predOnset: onset(p), refOffset: offset(r), predOffset: offset(p),
                      refTST: Double(r.filter(ReferenceStage.isSleep).count) * toMin,
                      predTST: Double(p.filter(ReferenceStage.isSleep).count) * toMin,
                      refStageMin: minutes(r), predStageMin: minutes(p), stage4: c4, sleepWake: c2)
}

/// The grid one night is scored on: from the earliest segment start to the latest segment end over both
/// hypnograms, epoch-aligned to the earliest start. `nil` when neither side has anything.
func sharedGrid(ref: [RefSegment], pred: [(start: Int, end: Int, stage: String)]) -> (start: Int, n: Int)? {
    let starts = ref.map(\.start) + pred.map(\.start)
    let ends = ref.map(\.end) + pred.map(\.end)
    guard let lo = starts.min(), let hi = ends.max(), hi > lo else { return nil }
    return (lo, Int(ceil(Double(hi - lo) / epochSeconds)))
}

/// Accuracy of the constant "always asleep" predictor on the same sleep/wake epochs — the figure R4 says
/// must sit next to any raw agreement on a mostly-asleep night.
func alwaysAsleepAccuracy(_ c: Confusion) -> Double {
    guard let s = c.classes.firstIndex(of: "sleep"), c.total > 0 else { return .nan }
    return Double(c.m[s].reduce(0, +)) / Double(c.total)
}
