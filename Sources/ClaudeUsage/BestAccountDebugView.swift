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
                Text(
                    "≈\(Int(percent.rounded()))% at risk before reset "
                        + "(\(units(atRiskUnits)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            var expiring =
                "Expiring-first: \(label(award.badgedID)) has \(units(award.atRiskUnits)) "
                + "at risk (floor ≥ \(units(BestAccount.atRiskFloor)))"
            if let gap = award.atRiskGapUnits {
                expiring += ", leads by \(units(gap)) "
                    + "(needs ≥ \(units(BestAccount.atRiskMargin)))."
            } else {
                expiring += "."
            }
            lines.append(expiring)
            lines.append("Best: \(label(award.badgedID)) — use it before its reset.")
            return lines
        }
    }

    /// The expiring-capacity preamble for a v2-decided group: the demand
    /// signal and why the expiring-first path stood down.
    private var prefixLines: [String] {
        var lines = poolLines
        switch trace.capacityFallback {
        case .noAggregatePace:
            lines.append("Expiring-first: no burn-rate data — using headroom ranking.")
        case .belowFloor(let topAtRiskUnits):
            lines.append(
                "Expiring-first: at most \(units(topAtRiskUnits)) at risk "
                    + "(floor ≥ \(units(BestAccount.atRiskFloor))) — using headroom ranking.")
        case .atRiskTooClose(let leaderID, let runnerUpID, let gapUnits):
            lines.append(
                "Expiring-first: \(label(leaderID)) leads \(label(runnerUpID)) by only "
                    + "\(units(gapUnits)) at risk (needs ≥ \(units(BestAccount.atRiskMargin))) "
                    + "— using headroom ranking.")
        case nil:
            break
        }
        return lines
    }

    /// Pooled-demand summary plus the honesty annotation when plans are
    /// missing and the pool fell back to equal weights.
    private var poolLines: [String] {
        var lines: [String] = []
        if trace.aggregatePace > 0 {
            lines.append(
                "Pooled demand: \(units(trace.aggregatePace))/h "
                    + "(1 unit = a full Pro session).")
        } else {
            lines.append("Pooled demand: no data.")
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
