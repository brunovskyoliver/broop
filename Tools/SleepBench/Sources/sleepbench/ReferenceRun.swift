import Foundation
import StrandAnalytics
import WhoopProtocol

// ReferenceRun.swift — section H, the `--reference <csv>` report. The scoring itself lives in Reference.swift
// as pure functions; this file only loads nights and prints.
//
// Two NOOP sources are scored against the same reference nights:
//   stored  — the `sleepSession` rows as the phone persisted them (whatever build wrote them);
//   replay  — `SleepStager.detectSleep` re-run over the raw streams by THIS build, over the window the app
//             reads for a day (`StreamReadCap.lookbackSeconds` before local midnight through the next local
//             midnight), with V2 staging, the strap's band sleep_state and the WRIST_OFF/ON intervals, as
//             `IntelligenceEngine` passes them. Run the bench at two commits to get a before/after of a
//             detection or staging change; `stored` stays fixed between the two runs.
// A session belongs to a reference night when it ENDS on the same local day as the night and lies within
// `matchPadSeconds` of it, which is how the app attributes a session to a day: a separate morning "nap" right
// after the main night is charged to that night, an evening nap on the previous day is not.
// Replay needs the raw streams. A night whose gravity covers less than `replayMinCoverage` of its reference
// minutes (raw retention has dropped it, or the strap was off) is listed and left out of the replay totals:
// the replay would be scoring missing data, not the recipe.

struct ReferenceOptions {
    var path: String
    var tz: TimeZone
    var replay: Bool
    var out: String?
}

let matchPadSeconds = 3 * 3600
let replayMinCoverage = 0.9

private struct NightRow {
    let key: String
    let source: String
    let score: NightScore
    let gridStart: Int
    /// False when replay had too little raw data for this night to say anything about the recipe.
    let scorable: Bool
}

func runReferenceReport(db: ReadOnlyDB, opts: ReferenceOptions, sessionDevice: String, streamDevice: String,
                        storedRows: [SessionRow]) throws {
    let text = try String(contentsOfFile: opts.path, encoding: .utf8)
    let nights = groupReferenceNights(try parseReferenceCSV(text))
    var cal = Calendar(identifier: .gregorian); cal.timeZone = opts.tz
    let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"; dayFmt.timeZone = opts.tz
    let hmFmt = DateFormatter(); hmFmt.dateFormat = "HH:mm"; hmFmt.timeZone = opts.tz
    func hm(_ gridStart: Int, _ minutes: Double?) -> String {
        guard let m = minutes else { return "  -  " }
        return hmFmt.string(from: Date(timeIntervalSince1970: Double(gridStart) + m * 60))
    }

    print("""

    ================================================================================
    H. EXTERNAL REFERENCE  (\(opts.path), \(nights.count) nights, tz \(opts.tz.identifier))
    ================================================================================
    Domain: per night, ONE 30 s grid from the earlier first segment to the later last segment of the two
    hypnograms; an epoch a side does not cover is wake on that side. Onset/offset are the first sleep epoch
    and the end of the last one. Errors are NOOP minus reference, in minutes (positive offset = NOOP ends
    later). 4-class kappa uses only epochs the reference stages; reference "asleep" with no stage counts
    toward TST and sleep/wake only. A consumer device is an estimate, not ground truth.
    """)

    typealias Pred = (segments: [(start: Int, end: Int, stage: String)], coverage: Double?)
    func localDay(_ ts: Int) -> Date { cal.startOfDay(for: Date(timeIntervalSince1970: Double(ts))) }
    func belongs(start: Int, end: Int, first: RefSegment, last: RefSegment) -> Bool {
        start < last.end + matchPadSeconds && first.start - matchPadSeconds < end
            && localDay(end) == localDay(last.end)
    }
    var sources: [(String, (RefSegment, RefSegment) -> Pred)] = []
    sources.append(("stored", { first, last in
        (storedRows.filter { belongs(start: $0.startTs, end: $0.endTs, first: first, last: last) }
            .flatMap { r in r.stages.map { (start: $0.start, end: $0.end, stage: canonicalPredStage($0.stage)) } }, nil)
    }))
    if opts.replay {
        sources.append(("replay", { first, last in
            let endDay = localDay(last.end)
            let dayStart = Int(endDay.timeIntervalSince1970)
            let nextStart = Int(cal.date(byAdding: .day, value: 1, to: endDay)!.timeIntervalSince1970)
            let from = dayStart - StreamReadCap.lookbackSeconds, to = nextStart
            guard let st = try? db.streams(device: streamDevice, from: from, to: to) else { return ([], 0) }
            let coverage = minuteCoverage(st.grav.map(\.ts), from: first.start, to: last.end)
            let events = (try? db.events(device: streamDevice, from: from, to: to)) ?? []
            let wristOff = AnalyticsEngine.offWristIntervals(events: events, windowEnd: to, hr: st.hr)
            let sessions = SleepStager.detectSleep(
                hr: st.hr, rr: st.rr, resp: st.resp, gravity: st.grav,
                tzOffsetSeconds: opts.tz.secondsFromGMT(for: endDay), wristOff: wristOff,
                bandSleepState: st.band, useSleepStagerV2: true)
            return (sessions.filter { belongs(start: $0.start, end: $0.end, first: first, last: last) }
                .flatMap { s in s.stages.map { (start: $0.start, end: $0.end, stage: canonicalPredStage($0.stage)) } },
                    coverage)
        }))
    }

    var rows: [NightRow] = []
    for (name, predFor) in sources {
        FileHandle.standardError.write(Data("scoring \(name) against \(nights.count) reference nights…\n".utf8))
        print("""

          H.\(name == "stored" ? 1 : 2) \(name.uppercased()) — per night
          night       ref onset-offset   TST | NOOP onset-offset   TST |  dOn  dOff  dTST | ref L/D/R/W        NOOP L/D/R/W       | 4c acc   k4 |   k2
        """)
        for night in nights {
            let ordered = night.sorted { $0.start < $1.start }
            guard let first = ordered.first, let last = night.max(by: { $0.end < $1.end }) else { continue }
            let key = dayFmt.string(from: Date(timeIntervalSince1970: Double(last.end)))
            let (pred, coverage) = predFor(first, last)
            guard let g = sharedGrid(ref: night, pred: pred) else { continue }
            let refL = labelsOnGrid(night.map { (start: $0.start, end: $0.end, stage: $0.stage) }, gridStart: g.start, n: g.n)
            let predL = labelsOnGrid(pred, gridStart: g.start, n: g.n)
            let s = scoreNight(ref: refL, pred: predL)
            let scorable = coverage.map { $0 >= replayMinCoverage } ?? true
            rows.append(NightRow(key: key, source: name, score: s, gridStart: g.start, scorable: scorable))
            if !scorable {
                print("  \(key)  raw gravity covers \(f((coverage ?? 0) * 100, 3, 0))% of the reference night — not scored")
                continue
            }
            func lr(_ m: [String: Double]) -> String {
                String(format: "%3.0f/%3.0f/%3.0f/%3.0f", (m["light"] ?? 0) + (m["sleep"] ?? 0), m["deep"] ?? 0, m["rem"] ?? 0, m["wake"] ?? 0)
            }
            print("  \(key)  \(hm(g.start, s.refOnset))-\(hm(g.start, s.refOffset)) \(f(s.refTST, 5, 0)) | \(hm(g.start, s.predOnset))-\(hm(g.start, s.predOffset)) \(f(s.predTST, 5, 0)) | \(f(s.onsetErr ?? .nan, 4, 0)) \(f(s.offsetErr ?? .nan, 5, 0)) \(f(s.tstErr, 5, 0)) | \(lr(s.refStageMin))  \(lr(s.predStageMin))  | \(f(s.stage4.accuracy * 100, 5, 1)) \(f(s.stage4.kappa, 5, 2)) | \(f(s.sleepWake.kappa, 5, 2))")
        }
        printTotals(rows.filter { $0.source == name }, name: name)
    }

    if let out = opts.out {
        var csv = "night,source,refOnsetMin,predOnsetMin,onsetErrMin,offsetErrMin,refTSTMin,predTSTMin,tstErrMin"
        for s in stageOrder { csv += ",ref\(s.capitalized)Min,pred\(s.capitalized)Min" }
        csv += ",refUnstagedMin,acc4,kappa4,kappa2\n"
        func num(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        for r in rows where r.scorable {
            let s = r.score
            csv += "\(r.key),\(r.source),\(num(s.refOnset)),\(num(s.predOnset)),\(num(s.onsetErr)),\(num(s.offsetErr)),\(num(s.refTST)),\(num(s.predTST)),\(num(s.tstErr))"
            for st in stageOrder { csv += ",\(num(s.refStageMin[st])),\(num(s.predStageMin[st]))" }
            csv += ",\(num(s.refStageMin["sleep"])),\(String(format: "%.4f", s.stage4.accuracy)),\(String(format: "%.4f", s.stage4.kappa)),\(String(format: "%.4f", s.sleepWake.kappa))\n"
        }
        try csv.write(toFile: out, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("wrote \(out)\n".utf8))
    }
}

/// Stored hypnograms carry both `wake` and `awake` (VALIDATION_PROTOCOL R7); fold through the one shared
/// predicate so a predicted wake is never misfiled as sleep.
func canonicalPredStage(_ s: String) -> String { SleepStageVocabulary.isWake(s) ? "wake" : s }

/// Fraction of the wall-clock minutes in `[from, to)` holding at least one sample time.
func minuteCoverage(_ times: [Int], from: Int, to: Int) -> Double {
    guard to > from else { return 0 }
    let lo = from / 60, hi = (to - 1) / 60
    let hit = Set(times.lazy.filter { $0 >= from && $0 < to }.map { $0 / 60 })
    return Double(hit.count) / Double(hi - lo + 1)
}

private func printTotals(_ all: [NightRow], name: String) {
    let rows = all.filter(\.scorable)
    let unscorable = all.filter { !$0.scorable }.map(\.key)
    if !unscorable.isEmpty { print("\n  not scored (raw data missing): \(unscorable.joined(separator: ", "))") }
    let both = rows.filter { $0.score.predTST > 0 && $0.score.refTST > 0 }
    let missing = rows.filter { $0.score.predTST == 0 && $0.score.refTST > 0 }.map(\.key)
    let on = both.compactMap { $0.score.onsetErr }, off = both.compactMap { $0.score.offsetErr }
    let tst = both.map { $0.score.tstErr }
    func line(_ label: String, _ v: [Double]) {
        print("    \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) n=\(v.count)  mean \(f(mean(v), 6, 1))  median \(f(median(v), 6, 1))  MAE \(f(mae(v), 5, 1))  sd \(f(sd(v), 5, 1))  range \(f(v.min() ?? .nan, 5, 0))..\(f(v.max() ?? .nan, 4, 0))")
    }
    print("\n  H.\(name == "stored" ? 1 : 2) \(name.uppercased()) — month totals (nights where both sides have sleep: \(both.count); NOOP has none: \(missing.isEmpty ? "-" : missing.joined(separator: ", ")))")
    line("onset err", on); line("offset err", off); line("TST err", tst)
    // Per-stage minutes and share of TST, mean over nights. Reference light includes its unstaged "asleep".
    print("    stage    ref min  NOOP min  bias min   ref %TST  NOOP %TST")
    for st in ["light", "deep", "rem", "wake"] {
        let r = both.map { ($0.score.refStageMin[st] ?? 0) + (st == "light" ? ($0.score.refStageMin["sleep"] ?? 0) : 0) }
        let p = both.map { $0.score.predStageMin[st] ?? 0 }
        let rp = zip(r, both).map { st == "wake" ? Double.nan : $0 / max(1, $1.score.refTST) * 100 }
        let pp = zip(p, both).map { st == "wake" ? Double.nan : $0 / max(1, $1.score.predTST) * 100 }
        print("    \(st.padding(toLength: 6, withPad: " ", startingAt: 0)) \(f(mean(r), 9, 1)) \(f(mean(p), 9, 1)) \(f(mean(p) - mean(r), 9, 1)) \(f(mean(rp), 10, 1)) \(f(mean(pp), 10, 1))")
    }
    var c4 = Confusion(classes: stageOrder), c2 = Confusion(classes: ["wake", "sleep"])
    for r in both { c4.merge(r.score.stage4); c2.merge(r.score.sleepWake) }
    let k4 = both.map { $0.score.stage4.kappa }.filter { !$0.isNaN }
    print("    pooled 4-class acc \(f(c4.accuracy * 100, 5, 1))%  kappa \(f(c4.kappa, 6, 3))  (epochs \(c4.total); mean per-night kappa \(f(mean(k4), 6, 3)))")
    for s in stageOrder {
        let (sens, spec, n) = c4.sensSpec(s)
        print("      \(s.padding(toLength: 6, withPad: " ", startingAt: 0)) sens \(f(sens * 100, 5, 1))%  spec \(f(spec * 100, 5, 1))%  (ref epochs \(n))")
    }
    print("    pooled sleep/wake acc \(f(c2.accuracy * 100, 5, 1))%  kappa \(f(c2.kappa, 6, 3))  wake sens \(f(c2.sensSpec("wake").sens * 100, 5, 1))%  — constant \"always asleep\" scores \(f(alwaysAsleepAccuracy(c2) * 100, 5, 1))% on the same epochs")
}
