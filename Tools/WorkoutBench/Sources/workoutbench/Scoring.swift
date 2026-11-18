import Foundation

// Scoring primitives for WorkoutBench. Pure functions over time spans: no database, no detector.

/// A closed-open `[start, end)` span in unix seconds.
struct Span: Equatable {
    let start: Int
    let end: Int
    var length: Int { max(0, end - start) }
    func overlap(_ o: Span) -> Int { max(0, min(end, o.end) - max(start, o.start)) }
}

/// The coarse family a label's sport belongs to, on the classifier's own taxonomy so the two can be
/// compared. `other` covers every sport the classifier has no class for (swimming, court sports).
enum SportFamily: String, CaseIterable {
    case walk, run, strength, cycle, ski, other

    /// Substring match on the lowercased sport with spaces removed, so "Weightlifting", "Strength
    /// Training" and Apple's "TraditionalStrengthTraining" all land on `strength`.
    static func of(sport: String) -> SportFamily {
        let s = sport.lowercased().replacingOccurrences(of: " ", with: "")
        func has(_ words: [String]) -> Bool { words.contains { s.contains($0) } }
        if has(["weight", "strength", "lift", "powerlift", "functional", "crossfit"]) { return .strength }
        if has(["walk", "hik"]) { return .walk }
        if has(["run", "jog"]) { return .run }
        if has(["cycl", "bik", "spin"]) { return .cycle }
        if has(["ski", "snowboard"]) { return .ski }
        return .other
    }
}

/// One detected session as the scorer sees it.
struct DetectedSpan: Equatable {
    let span: Span
    /// The classifier's class token, nil when it returned `other` or was not run.
    let suggestedClass: String?
}

/// How one label fared against the detected sessions.
struct LabelScore: Equatable {
    /// Share of the label's own duration that some detected session covers, 0...1.
    let coveredFrac: Double
    /// Detected sessions overlapping the label. More than one means the detector fragmented it.
    let pieces: Int
    /// Seconds the overlapping sessions run outside the label: what was attached to it that the wearer
    /// did not log (the walk to the gym on a lift).
    let spillS: Int
    /// Earliest overlapping start minus the label start, and latest overlapping end minus the label end.
    /// Negative start = detected earlier; nil when nothing overlaps.
    let startErrS: Int?
    let endErrS: Int?
    /// The suggested class holding the most overlap seconds, nil when no overlapping piece carried one.
    let classByOverlap: String?
}

enum Scoring {
    /// A label counts as found when at least this share of it is covered.
    static let foundCoverage = 0.5

    static func score(label: Span, detected: [DetectedSpan]) -> LabelScore {
        let hits = detected.filter { $0.span.overlap(label) > 0 }.sorted { $0.span.start < $1.span.start }
        guard !hits.isEmpty, label.length > 0 else {
            return LabelScore(coveredFrac: 0, pieces: 0, spillS: 0, startErrS: nil, endErrS: nil,
                              classByOverlap: nil)
        }
        // Union of the overlaps, so two sessions that overlap each other cannot count a second twice.
        var covered = 0
        var cursor = label.start
        for h in hits {
            let a = max(cursor, max(h.span.start, label.start)), b = min(h.span.end, label.end)
            if b > a { covered += b - a; cursor = b }
        }
        let spill = hits.reduce(0) { $0 + $1.span.length - $1.span.overlap(label) }
        var byClass: [String: Int] = [:]
        for h in hits { if let c = h.suggestedClass { byClass[c, default: 0] += h.span.overlap(label) } }
        // Ties broken by name so the answer does not depend on dictionary order.
        let top = byClass.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
        return LabelScore(
            coveredFrac: Double(covered) / Double(label.length), pieces: hits.count, spillS: spill,
            startErrS: hits.map(\.span.start).min().map { $0 - label.start },
            endErrS: hits.map(\.span.end).max().map { $0 - label.end },
            classByOverlap: top)
    }

    /// Detected sessions that overlap no label. NOT false positives by themselves: an unlogged walk is a
    /// real bout. The count is a volume figure, to be read against how many sessions a day is plausible.
    static func unlabelled(_ detected: [DetectedSpan], labels: [Span]) -> [DetectedSpan] {
        detected.filter { d in !labels.contains { $0.overlap(d.span) > 0 } }
    }

    /// Collapse labels that describe the same session twice (a watch workout and its manual twin): of two
    /// labels where the overlap covers at least half the shorter one, the earlier-listed is kept. Callers
    /// order the input by trust.
    static func dedup<T>(_ labels: [T], span: (T) -> Span) -> [T] {
        var kept: [T] = []
        for l in labels {
            let s = span(l)
            let twin = kept.contains { k in
                let ks = span(k)
                let shorter = min(s.length, ks.length)
                return shorter > 0 && Double(s.overlap(ks)) >= 0.5 * Double(shorter)
            }
            if !twin { kept.append(l) }
        }
        return kept
    }
}
