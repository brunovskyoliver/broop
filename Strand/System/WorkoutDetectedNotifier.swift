import Foundation
import StrandAnalytics
import UserNotifications

// MARK: - Detected-workout notifications
//
// 2026-11-18: revived for auto-save. After every analysis pass, `onAnalysisPass` runs the auto-save
// (`Repository.runWorkoutAutoSave`) and then posts:
//  - one notification per workout that pass saved ("Workout saved"), with a Delete action;
//  - at most one for the newest open suggestion of `WorkoutAutoSave.minDurationS` or longer that has not
//    been announced yet ("Looks like a workout"), with Save and "Not a workout" actions.
// The settled-token set below keeps a suggestion from being announced twice as its bounds drift between
// passes. Posting is gated on the `workoutDetectedNotify` toggle (default ON) and on the system
// permission; the auto-save itself is not, so turning notifications off never loses a workout.
//
// Battery: the detection reads what the pass already wrote and is cached per day (`detectWorkouts`),
// so a quiet tick re-detects only the day whose streams changed.
//
// The legacy category (Edit / "Not a workout" on a persisted `sport="detected"` row) stays registered for
// notifications delivered by older builds.

/// Pure policy + copy for the detected-workout notification — no UserNotifications types, so the
/// decision logic is pinned by unit tests independently of the notification plumbing. Kotlin twin:
/// `com.noop.notif.WorkoutDetectedPolicy` (same constants, same semantics).
enum WorkoutDetectedPolicy {

    /// One detected-bout candidate, built from a persisted `sport="detected"` row.
    struct Candidate: Equatable, Sendable {
        var startTs: Int
        var endTs: Int
        var avgHr: Int?
        var maxHr: Int?
        /// The classifier's advisory token ("walk"/"run"/"strength"/"cycle"/"ski"), copied from the
        /// row's `suggestedClass`. nil when the classifier had nothing to say — the copy then makes
        /// no activity claim at all.
        var suggestedClass: String? = nil
    }

    /// The pass decision: the single bout to notify about (newest eligible), plus EVERY eligible
    /// span token to mark settled — not just the notified one, so a pass with several fresh bouts
    /// can never trickle out extra notifications on later passes.
    struct Decision: Equatable, Sendable {
        var notify: Candidate?
        var settledTokens: [String]
    }

    /// A bout must have been over this long before we talk about it: the detector extends a live
    /// bout across a sync boundary, so notifying on first sight could fire mid-workout. 600 s also
    /// lands the notification ~10-25 min post-exercise on the normal offload cadence.
    static let notifySettleSec = 600
    /// Candidates are only considered inside this lookback — an ancient re-detect never notifies.
    static let candidateWindowSec = 36 * 3600
    /// Persisted-token hygiene: spans older than this are pruned and the set is capped, so the
    /// UserDefaults list can't grow without bound across process restarts.
    static let maxTokenAgeSec = 30 * 86_400
    static let maxTokens = 200

    /// The "startTs:endTs" token persisted for a settled span — same shape as the
    /// dismissed-detected tokens (`WorkoutSource.dismissedToken`), so the two span lists can share
    /// `WorkoutSource.parseDismissedSpans`.
    static func token(startTs: Int, endTs: Int) -> String { "\(startTs):\(endTs)" }

    /// Half-open overlap test — identical to `WorkoutSource.isDismissed`'s span check.
    static func overlaps(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Bool {
        aStart < bEnd && bStart < aEnd
    }

    /// Pick the newest notify-eligible bout and every eligible token to settle.
    ///
    /// A candidate is eligible when ALL hold:
    ///  - it ended at least `notifySettleSec` ago (can't fire mid-workout);
    ///  - it does not overlap a dismissed span (the user already said "not a workout" — matching
    ///    the read-time filter that hides it from the Workouts list);
    ///  - it does not overlap a real (manual / imported / live) session span — mirrors the
    ///    engine's own persist-time overlap suppression and covers a real row imported after the
    ///    detected twin was persisted;
    ///  - it does not overlap an already-settled span (drift-tolerant re-notification guard).
    ///
    /// [realSpans] and [dismissedSpans] are (start,end) pairs; [settledSpans] comes from parsing
    /// the persisted token set. Deterministic: newest by endTs, then startTs.
    static func decide(
        nowSec: Int,
        candidates: [Candidate],
        realSpans: [(start: Int, end: Int)],
        dismissedSpans: [(start: Int, end: Int)],
        settledSpans: [(start: Int, end: Int)]
    ) -> Decision {
        let eligible = candidates.filter { c in
            c.endTs <= nowSec - notifySettleSec
                && !dismissedSpans.contains { overlaps(c.startTs, c.endTs, $0.start, $0.end) }
                && !realSpans.contains { overlaps(c.startTs, c.endTs, $0.start, $0.end) }
                && !settledSpans.contains { overlaps(c.startTs, c.endTs, $0.start, $0.end) }
        }
        let notify = eligible.max { a, b in
            a.endTs != b.endTs ? a.endTs < b.endTs : a.startTs < b.startTs
        }
        return Decision(notify: notify,
                        settledTokens: eligible.map { token(startTs: $0.startTs, endTs: $0.endTs) }
                            .sorted())
    }

    /// Prune the persisted settled-token set: drop malformed entries, spans older than
    /// `maxTokenAgeSec`, and overflow beyond `maxTokens` keeping the newest starts. Returns a
    /// sorted (by startTs) list so the persisted value is deterministic and testable.
    static func prunedTokens(_ tokens: [String], nowSec: Int) -> [String] {
        let spans = tokens.compactMap { t -> (start: Int, end: Int, raw: String)? in
            let p = t.split(separator: ":")
            guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]), b > a else { return nil }
            return (a, b, t)
        }
        let fresh = spans.filter { $0.end > nowSec - maxTokenAgeSec }
        let kept = fresh.sorted { $0.start > $1.start }.prefix(maxTokens)
        return kept.map(\.raw).sorted()
    }

    /// "47 min" / "1 h 23 min" — byte-mirrors Android `ScheduledReportPolicy.durationLabel` so the
    /// notification body reads identically on both platforms.
    static func durationLabel(minutes: Int) -> String {
        if minutes <= 0 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The measured-facts fragment ("47 min · avg 104 bpm · peaked 140 bpm"). Locale-neutral unit
    /// notation — the Apple notifier interpolates it into the localized sentence frame; Android
    /// posts it through [copy]'s full English body. avg/peak are omitted when absent, never
    /// invented, and no sport is claimed — attribution discipline: only what the detector measured.
    static func metricsText(_ c: Candidate) -> String {
        var parts = [durationLabel(minutes: (c.endTs - c.startTs) / 60)]
        if let avg = c.avgHr { parts.append("avg \(avg) bpm") }
        if let peak = c.maxHr { parts.append("peaked \(peak) bpm") }
        return parts.joined(separator: " · ")
    }

    /// English display name for a classifier token, for the Android verbatim body. nil for
    /// "other"/unknown tokens — they make no claim. The Apple path re-localizes the same token
    /// through `WorkoutSource.suggestedClassName` instead of using this string.
    static func classLabel(_ token: String?) -> String? {
        switch token {
        case "walk":     "Walking"
        case "run":      "Running"
        case "strength": "Strength Training"
        case "cycle":    "Cycling"
        case "ski":      "Skiing"
        default:         nil
        }
    }

    /// Title + full English body (the Android notifier posts these verbatim; the Apple notifier
    /// rebuilds the same text through the localized frame in `onAnalysisPass`). The frame tells
    /// the user the row is already saved, so the tap reads as review, not approval. When the bout
    /// carried a classifier suggestion the body names it — hedged ("looks like") because it is an
    /// advisory guess, not a measured fact.
    static func copy(_ c: Candidate) -> (title: String, body: String) {
        let tail = "Saved to Workouts — tap to review."
        guard let label = classLabel(c.suggestedClass) else {
            return ("Activity detected", metricsText(c) + ". " + tail)
        }
        return ("Activity detected",
                metricsText(c) + " — looks like \(label). " + tail)
    }

    /// "Workout saved" copy for a session the auto-save stored. `sport` is the stored sport's display
    /// name. The body says where it came from, so a wrong save reads as the detector's, not the wearer's.
    static func savedCopy(_ c: Candidate, sport: String) -> (title: String, body: String) {
        ("Workout saved", "\(sport) · " + metricsText(c) + ". Detected from your strap — delete it if it was not a workout.")
    }

    /// "Looks like a workout" copy for an open suggestion: the hedged class name when there is one.
    static func suggestedCopy(_ c: Candidate) -> (title: String, body: String) {
        guard let label = classLabel(c.suggestedClass) else {
            return ("Looks like a workout", metricsText(c) + ". Save it?")
        }
        return ("Looks like a workout", metricsText(c) + " — looks like \(label). Save it?")
    }
}

/// The notification plumbing: categories, posting, and the post-pass hook `IntelligenceEngine` calls.
enum WorkoutDetectedNotifier {

    /// Legacy category for notifications delivered by builds that persisted `sport="detected"` rows.
    static let categoryId = "workout.detected"
    static let actionEditId = "workout.detected.edit"
    static let actionDismissId = "workout.detected.dismiss"
    /// A workout the auto-save stored. Delete removes it and dismisses its span.
    static let savedCategoryId = "workout.autosaved"
    static let actionDeleteId = "workout.autosaved.delete"
    /// An open suggestion. Save stores it as the card would; "Not a workout" dismisses it.
    static let suggestedCategoryId = "workout.suggested"
    static let actionSaveId = "workout.suggested.save"
    static let actionNotWorkoutId = "workout.suggested.dismiss"

    /// userInfo keys — local epoch-second identifiers only; the handlers re-resolve the row or suggestion.
    static let infoStartTs = "startTs"
    static let infoEndTs = "endTs"

    /// `enabledDefaultsKey` is the Settings toggle, default ON since auto-save (a saved workout nobody is
    /// told about is how eleven lifts went unseen); `notifiedDefaultsKey` holds announced suggestion spans.
    static let enabledDefaultsKey = "workoutDetectedNotify"
    static let notifiedDefaultsKey = "workouts.detectedNotified"

    /// How long a suggestion stays on the card (and so how far back auto-save looks once a day).
    static let suggestionLifetimeDays = 7
    static let fullScanDayKey = "workouts.autoSaveFullScanDay"

    static func requestId(startTs: Int) -> String { "workout.detected.\(startTs)" }

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    /// Every category this notifier has posted under, registered at launch.
    static var categories: Set<UNNotificationCategory> {
        let edit = UNNotificationAction(identifier: actionEditId, title: String(localized: "Edit"),
                                        options: [.foreground])
        let dismiss = UNNotificationAction(identifier: actionDismissId, title: String(localized: "Not a workout"),
                                           options: [.destructive])
        let delete = UNNotificationAction(identifier: actionDeleteId, title: String(localized: "Delete"),
                                          options: [.destructive])
        let save = UNNotificationAction(identifier: actionSaveId, title: String(localized: "Save"), options: [])
        let notWorkout = UNNotificationAction(identifier: actionNotWorkoutId,
                                              title: String(localized: "Not a workout"), options: [.destructive])
        return [
            UNNotificationCategory(identifier: categoryId, actions: [edit, dismiss], intentIdentifiers: []),
            UNNotificationCategory(identifier: savedCategoryId, actions: [delete], intentIdentifiers: []),
            UNNotificationCategory(identifier: suggestedCategoryId, actions: [save, notWorkout], intentIdentifiers: []),
        ]
    }

    /// The same authorization request every notifier makes: from the Settings toggle, and from the first
    /// pass that has something to say while the wearer has never been asked.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post-pass hook, called from `IntelligenceEngine.analyzeRecent` on every invocation, including passes
    /// the fingerprint gate skipped: a session becomes due for saving once it has been over for
    /// `WorkoutDetector.stitchMaxGapS`, which can elapse during a quiet tick.
    static func onAnalysisPass(repository: Repository) async {
        // The first pass of each local day covers the whole suggestion lifetime, so a phone that was off
        // for days still saves what the card would show; later passes cover the last two days.
        let today = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let fullScan = UserDefaults.standard.integer(forKey: fullScanDayKey) != today
        let (saved, open) = await repository.runWorkoutAutoSave(daysBack: fullScan ? suggestionLifetimeDays : 2)
        if fullScan { UserDefaults.standard.set(today, forKey: fullScanDayKey) }
        guard enabled else { return }
        let now = Int(Date().timeIntervalSince1970)
        let settled = UserDefaults.standard.stringArray(forKey: notifiedDefaultsKey) ?? []
        let suggestions = open.filter { $0.endSec - $0.startSec >= WorkoutAutoSave.minDurationS }
            .map { WorkoutDetectedPolicy.Candidate(startTs: $0.startSec, endTs: $0.endSec, avgHr: $0.avgBpm,
                                                   maxHr: $0.peakBpm, suggestedClass: $0.suggestedClass) }
        let decision = WorkoutDetectedPolicy.decide(
            nowSec: now, candidates: suggestions, realSpans: [], dismissedSpans: [],
            settledSpans: WorkoutSource.parseDismissedSpans(settled))
        guard !saved.isEmpty || decision.notify != nil else { return }

        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }

        for row in saved {
            let c = WorkoutDetectedPolicy.Candidate(startTs: row.startTs, endTs: row.endTs, avgHr: row.avgHr,
                                                    maxHr: row.maxHr, suggestedClass: row.suggestedClass)
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Workout saved")
            let sport = WorkoutSource.displaySport(row.sport)
            let metrics = WorkoutDetectedPolicy.metricsText(c)
            content.body = String(localized: "\(sport) · \(metrics). Detected from your strap — delete it if it was not a workout.")
            await post(content, category: savedCategoryId, startTs: row.startTs, endTs: row.endTs)
        }
        if let bout = decision.notify {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Looks like a workout")
            let metrics = WorkoutDetectedPolicy.metricsText(bout)
            if let name = WorkoutSource.suggestedClassName(bout.suggestedClass) {
                content.body = String(localized: "\(metrics) — looks like \(name). Save it?")
            } else {
                content.body = String(localized: "\(metrics). Save it?")
            }
            if await post(content, category: suggestedCategoryId, startTs: bout.startTs, endTs: bout.endTs) {
                // Mark settled only after a successful post: a failed delivery keeps its chance next pass.
                var tokens = settled
                for t in decision.settledTokens where !tokens.contains(t) { tokens.append(t) }
                UserDefaults.standard.set(WorkoutDetectedPolicy.prunedTokens(tokens, nowSec: now),
                                          forKey: notifiedDefaultsKey)
            }
        }
        if TestCentre.active(.workouts), let workoutsLog = await repository.workoutsLog {
            workoutsLog("workout notify saved=\(saved.count) suggested=\(decision.notify == nil ? 0 : 1) "
                        + "settled=\(decision.settledTokens.count)")
        }
    }

    @discardableResult
    private static func post(_ content: UNMutableNotificationContent, category: String,
                             startTs: Int, endTs: Int) async -> Bool {
        content.categoryIdentifier = category
        content.sound = .default
        content.userInfo = [infoStartTs: startTs, infoEndTs: endTs]
        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: requestId(startTs: startTs), content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }
}
