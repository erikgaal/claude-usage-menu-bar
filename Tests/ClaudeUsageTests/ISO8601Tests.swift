import XCTest

@testable import ClaudeUsage

/// `ISO8601.parse` feeds every `resetsAt` in the Claude data path. The API
/// sends 6-digit fractional seconds, which `ISO8601DateFormatter` cannot
/// parse directly — the fraction-stripping fallback must cover that.
final class ISO8601Tests: XCTestCase {

    /// 2033-05-18T03:33:20Z.
    private static let epoch: TimeInterval = 2_000_000_000

    func testParsesPlainInternetDateTime() {
        XCTAssertEqual(
            ISO8601.parse("2033-05-18T03:33:20Z"),
            Date(timeIntervalSince1970: Self.epoch))
    }

    func testParsesThreeDigitFractionalSeconds() throws {
        let date = try XCTUnwrap(ISO8601.parse("2033-05-18T03:33:20.500Z"))
        XCTAssertEqual(date.timeIntervalSince1970, Self.epoch + 0.5, accuracy: 0.001)
    }

    func testParsesSixDigitFractionalSecondsWithoutShiftingTheSecond() throws {
        // The API sends 6 fractional digits. Depending on the Foundation
        // version the formatter either parses them at millisecond precision
        // (current macOS truncates to .123) or rejects them, in which case
        // the strip-and-retry fallback drops the fraction entirely. Pinned:
        // the parse succeeds and lands inside the right second, never
        // rounding up or failing.
        let date = try XCTUnwrap(ISO8601.parse("2033-05-18T03:33:20.123456Z"))
        XCTAssertGreaterThanOrEqual(date.timeIntervalSince1970, Self.epoch)
        XCTAssertLessThan(date.timeIntervalSince1970, Self.epoch + 0.124)
    }

    func testParsesTimezoneOffsets() {
        XCTAssertEqual(
            ISO8601.parse("2033-05-18T05:33:20+02:00"),
            Date(timeIntervalSince1970: Self.epoch))
    }

    func testNilEmptyAndGarbageReturnNil() {
        XCTAssertNil(ISO8601.parse(nil))
        XCTAssertNil(ISO8601.parse(""))
        XCTAssertNil(ISO8601.parse("not a date"))
        // Date-only strings are not internet date-times.
        XCTAssertNil(ISO8601.parse("2033-05-18"))
    }
}
