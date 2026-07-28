import SwiftUI

/// Popover breakdown of the "Best" badge decision for one provider group:
/// each account's inputs (session %, veto status, pace projection) followed
/// by the decision lines (headroom margin, pace override, final verdict).
/// Plain diagnostics, available in release builds — reachable from every
/// account row's context menu and by clicking the badge itself. Renders the
/// `BestAccount.GroupTrace` the real ranking produced, so it can never show
/// anything other than what actually decided the badge.
struct BestAccountDebugView: View {
    let trace: BestAccount.GroupTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Best-account hint — \(trace.provider.displayName)")
                .font(.caption.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(trace.candidates, id: \.accountID) { candidate in
                    candidateView(candidate)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                ForEach(decisionLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: Candidates

    private func candidateView(_ candidate: BestAccount.CandidateTrace) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(candidate.label)
                    .font(.caption.weight(.semibold))
                if let percent = candidate.sessionPercent {
                    Text("\(candidate.sessionName ?? "Session") \(Int(percent.rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(planText(candidate))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if isBadged(candidate) {
                    Text("Best")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Text(statusText(candidate))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Expiring-capacity input (issue #19), shown whenever the group
            // has a demand signal at all — including 0, which explains why
            // an account was passed over. Own-percent first, pooled units
            // alongside so mixed tiers stay comparable.
            if trace.aggregatePace > 0,
                let percent = candidate.atRiskPercent,
                let atRiskUnits = candidate.atRiskUnits {
                // A refilling session window is held at zero on purpose (v5);
                // say so, or the 0 reads as a missing signal.
                Text(
                    candidate.sessionRefills
                        ? "session refills before the weekly reset — nothing at risk"
                        : "≈\(Int(percent.rounded()))% at risk before reset "
                            + "(\(units(atRiskUnits)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // The weekly leg's input (issue #21), in weekly units — never
            // comparable with the session line above, so it names its window
            // and its reset explicitly.
            if trace.weeklyAggregatePace > 0,
                let percent = candidate.weeklyAtRiskPercent,
                let atRiskUnits = candidate.weeklyAtRiskUnits {
                Text(
                    "≈\(Int(percent.rounded()))% of "
                        + "\(candidate.weeklyName ?? "weekly") at risk before "
                        + "\(weeklyResetText(candidate)) (\(units(atRiskUnits)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "reset in 3d 0h" for a live weekly window, plain "reset" when the API
    /// reported none (nothing can expire, so there is no clock to show).
    private func weeklyResetText(_ candidate: BestAccount.CandidateTrace) -> String {
        guard let resetsAt = candidate.weeklyResetsAt, resetsAt > Date() else {
            return "reset"
        }
        return "reset in \(AccountSection.durationText(until: resetsAt))"
    }

    /// A bare interval as "2d 15h" — `AccountSection.durationText` measures
    /// from now, and this is a gap between two future resets.
    private func leadText(_ seconds: TimeInterval) -> String {
        AccountSection.durationText(until: Date().addingTimeInterval(seconds))
    }

    private func planText(_ candidate: BestAccount.CandidateTrace) -> String {
        guard let quota = candidate.quota else { return "plan not set" }
        let value = quota.multiplier == quota.multiplier.rounded()
            ? String(Int(quota.multiplier)) : String(format: "%.1f", quota.multiplier)
        return quota.source == .detected ? "×\(value) (auto)" : "×\(value)"
    }

    private func isBadged(_ candidate: BestAccount.CandidateTrace) -> Bool {
        switch trace.decision {
        case .badged(let award):
            return award.badgedID == candidate.accountID
        case .expiringFirst(let award):
            return award.badgedID == candidate.accountID
        case .groupTooSmall, .allVetoed, .marginTooClose:
            return false
        }
    }

    /// Veto reason when out of the running, pace signal otherwise — the
    /// display mapping for the trace's data-only reasons.
    private func statusText(_ candidate: BestAccount.CandidateTrace) -> String {
        switch candidate.eligibility {
        case .vetoedNeedsReauth:
            return "vetoed — sign-in expired"
        case .vetoedNoData:
            return "vetoed — no data yet"
        case .vetoedWeeklyExhausted(let limitName, let percent):
            return "vetoed — \(limitName) at \(Int(percent.rounded()))%, week spent"
        case .eligible:
            return paceText(candidate.pace)
        }
    }

    private func paceText(_ pace: BestAccount.PaceSignal) -> String {
        switch pace {
        case .noProjection:
            return "no pace data"
        case .stale:
            return "pace data stale — ignored"
        case .beyondReset:
            return "outlasts this window at current pace"
        case .projected(let date):
            return "≈\(AccountSection.durationText(until: date)) left at current pace"
        }
    }

    // MARK: Decision

    private var decisionLines: [String] {
        switch trace.decision {
        case .groupTooSmall:
            return ["Only one \(trace.provider.displayName) account — nothing to compare."]
        case .allVetoed:
            return ["No badge: every account is vetoed."]
        case .marginTooClose(let winnerID, let runnerUpID, let gap):
            return prefixLines + [
                "Headroom: \(label(winnerID)) leads \(label(runnerUpID)) by "
                    + "\(points(gap)) — needs ≥ \(points(BestAccount.margin)).",
                "No badge: too close to call.",
            ]
        case .badged(let award):
            var lines = prefixLines
            if let gap = award.headroomGap {
                lines.append(
                    "Headroom: \(label(award.headroomWinnerID)) leads by "
                        + "\(points(gap)) (needs ≥ \(points(BestAccount.margin))).")
            } else {
                lines.append(
                    "Headroom: \(label(award.headroomWinnerID)) is the only eligible account.")
            }
            lines.append(paceLine(award))
            lines.append("Best: \(label(award.badgedID)).")
            return lines
        case .expiringFirst(let award):
            var lines = poolLines
            // The weekly leg is only ever reached because the session leg
            // stood down, so show that stand-down reason first (issue #21).
            if award.leg == .weekly {
                lines += fallbackLines(
                    trace.capacityFallback, leg: .session, handingOff: true)
            }
            let name = legName(award.leg)
            var expiring =
                "\(name): \(label(award.badgedID)) has \(units(award.atRiskUnits)) "
                + "at risk (floor ≥ \(units(floorUnits(of: award.leg))))"
            // Which comparisons it had to win (v5). Both can apply: beating a
            // rival that shares its deadline on size, and leading everyone
            // later on the clock.
            var beats: [String] = []
            if let gap = award.atRiskGapUnits {
                beats.append(
                    "leads its same-reset rival by \(units(gap)) "
                        + "(needs ≥ \(units(marginUnits(of: award.leg))))")
            }
            if let lead = award.deadlineLeadSeconds {
                beats.append("resets \(leadText(lead)) before the next account")
            }
            expiring += beats.isEmpty ? "." : ", " + beats.joined(separator: ", ") + "."
            lines.append(expiring)
            lines.append("Best: \(label(award.badgedID)) — use it before its reset.")
            return lines
        }
    }

    /// The expiring-capacity preamble for a v2-decided group: the demand
    /// signal and why each expiring-first leg stood down.
    private var prefixLines: [String] {
        poolLines
            + fallbackLines(trace.capacityFallback, leg: .session)
            + fallbackLines(trace.weeklyCapacityFallback, leg: .weekly)
    }

    /// Why one leg stood down, in its own units and against its own
    /// constants — nothing when that leg decided or was never consulted.
    ///
    /// `handingOff` says a later leg went on to decide, so the line must not
    /// claim the headroom ranking took over. Since v5 narrowed the session leg
    /// to windows that don't simply refill, standing down and handing off to
    /// the weekly leg is its ordinary outcome rather than a rare one.
    private func fallbackLines(
        _ fallback: BestAccount.CapacityFallback?, leg: BestAccount.ExpiringAward.Leg,
        handingOff: Bool = false
    ) -> [String] {
        let name = legName(leg)
        let outcome = handingOff ? "deferring to the weekly leg" : "using headroom ranking"
        switch fallback {
        case .noAggregatePace:
            return ["\(name): no burn-rate data — \(outcome)."]
        case .belowFloor(let topAtRiskUnits):
            return [
                "\(name): at most \(units(topAtRiskUnits)) at risk "
                    + "(floor ≥ \(units(floorUnits(of: leg)))) — \(outcome)."
            ]
        case .atRiskTooClose(let leaderID, let runnerUpID, let gapUnits):
            return [
                "\(name): \(label(leaderID)) leads \(label(runnerUpID)) by only "
                    + "\(units(gapUnits)) at risk (needs ≥ \(units(marginUnits(of: leg)))) "
                    + "— \(outcome)."
            ]
        case nil:
            return []
        }
    }

    private func legName(_ leg: BestAccount.ExpiringAward.Leg) -> String {
        leg == .session ? "Expiring-first" : "Expiring-first (weekly)"
    }

    private func floorUnits(of leg: BestAccount.ExpiringAward.Leg) -> Double {
        leg == .session ? BestAccount.atRiskFloor : BestAccount.weeklyAtRiskFloor
    }

    private func marginUnits(of leg: BestAccount.ExpiringAward.Leg) -> Double {
        leg == .session ? BestAccount.atRiskMargin : BestAccount.weeklyAtRiskMargin
    }

    /// Pooled-demand summary for both legs plus the honesty annotation when
    /// plans are missing and the pool fell back to equal weights.
    private var poolLines: [String] {
        var lines: [String] = []
        if trace.aggregatePace > 0 {
            lines.append(
                "Pooled demand: \(units(trace.aggregatePace))/h "
                    + "(1 unit = a full Pro session).")
        } else {
            lines.append("Pooled demand: no data.")
        }
        if trace.weeklyAggregatePace > 0 {
            lines.append(
                "Pooled weekly demand: \(units(trace.weeklyAggregatePace))/h "
                    + "(1 unit = a full Pro week).")
        } else {
            lines.append("Pooled weekly demand: no data.")
        }
        if trace.quotaWeighting == .equalWeightsAssumed {
            lines.append("Plans not set — assuming equal quotas.")
        }
        return lines
    }

    private func paceLine(_ award: BestAccount.Award) -> String {
        switch award.paceComparison {
        case .soleCandidate:
            return "Pace: no runner-up to compare."
        case .missingSignal:
            return "Pace: missing projection on one side — headroom stands."
        case .winnerOutlastsWindow:
            return "Pace: \(label(award.headroomWinnerID)) outlasts its window — no override."
        case .runnerUpOutlastsWindow:
            return "Pace: runner-up outlasts its whole window — badge moves."
        case .delta(let delta):
            if award.overrideApplied {
                return "Pace: runner-up outlasts by \(duration(delta)) "
                    + "(≥ \(duration(BestAccount.overrideMargin))) — badge moves."
            }
            if delta > 0 {
                return "Pace: runner-up outlasts by only \(duration(delta)) "
                    + "(needs ≥ \(duration(BestAccount.overrideMargin))) — headroom stands."
            }
            return "Pace: \(label(award.headroomWinnerID)) also lasts longer — no override."
        }
    }

    // MARK: Formatting

    private func label(_ accountID: String) -> String {
        trace.candidates.first { $0.accountID == accountID }?.label ?? accountID
    }

    private func points(_ value: Double) -> String {
        String(format: "%.1f pp", value)
    }

    /// Pooled quota units (one full Pro session window = 1.0).
    private func units(_ value: Double) -> String {
        String(format: "%.2f units", value)
    }

    /// Reuses the panel's duration wording ("2h 10m") for a plain interval.
    /// The +1 s pad absorbs the clock re-read inside `durationText`, which
    /// would otherwise round an exact "30m" down to "29m".
    private func duration(_ seconds: TimeInterval) -> String {
        AccountSection.durationText(until: Date().addingTimeInterval(abs(seconds) + 1))
    }
}
