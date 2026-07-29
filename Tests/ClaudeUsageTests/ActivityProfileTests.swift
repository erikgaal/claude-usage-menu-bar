import XCTest

@testable import ClaudeUsage

/// Midnight UTC on 2025-06-15, and a calendar pinned to UTC to read it with.
/// Hour-of-day cells are keyed on *local* hours, so a fixture that means
/// "busy at 10:00" has to name the zone or it asserts something different on
/// a UTC runner than on a machine in London.
private let midnight = Date(timeIntervalSince1970: 1_749_945_600)
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func at(day: Int = 0, _ hour: Double) -> Date {
    midnight.addingTimeInterval(Double(day) * 86400 + hour * 3600)
}

final class ActivityProfileTests: XCTestCase {

    // MARK: Folding

    func testIntensityIsPointsPerObservedHour() {
        var profile = ActivityProfile()
        profile.add(points: 4, from: at(10), to: at(11), calendar: utc)
        XCTAssertEqual(profile.intensity(atHour: 10), 4, accuracy: 0.001)
    }

    func testStretchStraddlingAnHourBoundarySplitsProportionally() {
        var profile = ActivityProfile()
        // Half an hour either side of 11:00, so each hour is credited half the
        // time and half the points — the same 6 points/hour intensity.
        profile.add(points: 6, from: at(10.5), to: at(11.5), calendar: utc)
        XCTAssertEqual(profile.intensity(atHour: 10), 6, accuracy: 0.001)
        XCTAssertEqual(profile.intensity(atHour: 11), 6, accuracy: 0.001)
    }

    func testRefoldingTheSameHistoryChangesNothing() {
        var once = ActivityProfile()
        var twice = ActivityProfile()
        let stretches: [(Double, Double, Double)] = [(10, 11, 3), (11, 12, 5), (14, 15, 1)]
        for (from, to, points) in stretches {
            once.add(points: points, from: at(from), to: at(to), calendar: utc)
            twice.add(points: points, from: at(from), to: at(to), calendar: utc)
        }
        // The watermark makes a replay free, which is what lets the store
        // re-fold its whole sample file on every poll without bookkeeping.
        for (from, to, points) in stretches {
            twice.add(points: points, from: at(from), to: at(to), calendar: utc)
        }
        XCTAssertEqual(once, twice)
    }

    func testStretchesEndingAtOrBeforeTheWatermarkAreIgnored() {
        var profile = ActivityProfile()
        profile.add(points: 4, from: at(10), to: at(11), calendar: utc)
        profile.add(points: 99, from: at(9), to: at(10), calendar: utc)
        XCTAssertEqual(profile.intensity(atHour: 9), 4, accuracy: 0.001, "unobserved: reports the mean")
    }

    // MARK: Decay

    func testOlderEvidenceCountsHalfAsMuchAfterOneHalfLife() {
        var profile = ActivityProfile()
        // 4 points/hour, then 8 points/hour exactly one half-life later. The
        // older hour keeps half its weight, so the answer leans on the newer:
        // (4·0.5 + 8) / (0.5 + 1) = 6.67, not the unweighted 6.
        profile.add(points: 4, from: at(10), to: at(11), calendar: utc)
        let later = ActivityProfile.halfLife / 86400
        profile.add(
            points: 8, from: at(day: Int(later), 10), to: at(day: Int(later), 11), calendar: utc)
        XCTAssertEqual(profile.intensity(atHour: 10), 6.667, accuracy: 0.01)
    }

    func testDecayLeavesIntensityAloneWhenBehaviorIsUnchanged()  {
        var profile = ActivityProfile()
        profile.add(points: 4, from: at(10), to: at(11), calendar: utc)
        let later = Int(ActivityProfile.halfLife / 86400)
        profile.add(
            points: 4, from: at(day: later, 10), to: at(day: later, 11), calendar: utc)
        // Both numerator and denominator decay, so a steady routine reads the
        // same however long it has been going.
        XCTAssertEqual(profile.intensity(atHour: 10), 4, accuracy: 0.001)
    }

    // MARK: Unobserved hours

    func testHourNeverObservedReportsTheOverallMeanRatherThanZero() {
        var profile = ActivityProfile()
        for day in 0..<4 {
            profile.add(points: 3, from: at(day: day, 10), to: at(day: day, 11), calendar: utc)
        }
        // 03:00 has never been watched. Calling it idle would let a projection
        // claim knowledge it hasn't earned, so the profile's own mean stands in.
        XCTAssertEqual(profile.intensity(atHour: 3), 3, accuracy: 0.001)
    }

    func testHourObservedAndIdleReportsZero() {
        var profile = ActivityProfile()
        for day in 0..<4 {
            profile.add(points: 3, from: at(day: day, 10), to: at(day: day, 11), calendar: utc)
            profile.add(points: 0, from: at(day: day, 11), to: at(day: day, 12), calendar: utc)
        }
        // Watched, and nothing happened: that *is* knowledge, and it's the
        // whole reason a projection can stand still overnight.
        XCTAssertEqual(profile.intensity(atHour: 11), 0, accuracy: 0.001)
    }

    // MARK: Gating

    func testFreshProfileIsNotUsable() {
        XCTAssertFalse(ActivityProfile().isUsable)
    }

    func testProfileFromASingleAfternoonIsNotUsable() {
        var profile = ActivityProfile()
        profile.add(points: 8, from: at(9), to: at(17), calendar: utc)
        // Eight hours across eight cells: nowhere near a day/night cycle, so
        // it may not shape anything yet.
        XCTAssertFalse(profile.isUsable)
    }

    func testProfileBecomesUsableOnceItHasSeenSeveralWholeDays() {
        var profile = ActivityProfile()
        for day in 0..<3 {
            for hour in 0..<24 {
                profile.add(
                    points: (9..<17).contains(hour) ? 1 : 0,
                    from: at(day: day, Double(hour)), to: at(day: day, Double(hour + 1)),
                    calendar: utc)
            }
        }
        XCTAssertTrue(profile.isUsable)
    }

    // MARK: Integration

    func testExpectedPointsIntegratesTheHourlyIntensities() {
        var profile = ActivityProfile()
        for day in 0..<3 {
            for hour in 0..<24 {
                profile.add(
                    points: (9..<17).contains(hour) ? 2 : 0,
                    from: at(day: day, Double(hour)), to: at(day: day, Double(hour + 1)),
                    calendar: utc)
            }
        }
        // A whole day is eight active hours at 2 points each.
        XCTAssertEqual(
            profile.expectedPoints(from: at(day: 5, 0), to: at(day: 6, 0), calendar: utc),
            16, accuracy: 0.001)
        // An overnight stretch is worth nothing at all — the fact the straight
        // line could never represent.
        XCTAssertEqual(
            profile.expectedPoints(from: at(day: 5, 18), to: at(day: 6, 6), calendar: utc),
            0, accuracy: 0.001)
        // Half of one active hour is half its points.
        XCTAssertEqual(
            profile.expectedPoints(from: at(day: 5, 10), to: at(day: 5, 10.5), calendar: utc),
            1, accuracy: 0.001)
    }

    // MARK: Hour arithmetic

    func testHourPiecesSplitOnBoundariesAndPreserveTheSpan() {
        let pieces = ActivityProfile.hourPieces(from: at(9.75), to: at(12.25), calendar: utc)
        XCTAssertEqual(pieces.map(\.hour), [9, 10, 11, 12])
        XCTAssertEqual(pieces.map(\.hours), [0.25, 1, 1, 0.25])
        XCTAssertEqual(pieces.reduce(0) { $0 + $1.hours }, 2.5, accuracy: 0.001)
    }

    func testHourPiecesWrapAcrossMidnight() {
        let pieces = ActivityProfile.hourPieces(from: at(23.5), to: at(day: 1, 0.5), calendar: utc)
        XCTAssertEqual(pieces.map(\.hour), [23, 0])
    }

    func testEmptyAndInvertedSpansYieldNothing() {
        XCTAssertTrue(ActivityProfile.hourPieces(from: at(10), to: at(10), calendar: utc).isEmpty)
        XCTAssertTrue(ActivityProfile.hourPieces(from: at(11), to: at(10), calendar: utc).isEmpty)
    }

    // MARK: Persistence shape

    func testProfileRoundTripsThroughJSON() throws {
        var profile = ActivityProfile()
        profile.add(points: 5, from: at(10), to: at(11), calendar: utc)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            ActivityProfile.self, from: try encoder.encode(profile))
        XCTAssertEqual(restored, profile)
        XCTAssertTrue(restored.isWellFormed)
    }
}
