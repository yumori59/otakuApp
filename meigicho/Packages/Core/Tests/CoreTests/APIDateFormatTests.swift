import XCTest
@testable import Core

/// AC-N-02-T / AC-N-03-T / AC-N-04-T
final class APIDateFormatTests: XCTestCase {
    private var originalTimeZone: TimeZone!

    override func setUp() {
        super.setUp()
        originalTimeZone = NSTimeZone.default
    }

    override func tearDown() {
        NSTimeZone.default = originalTimeZone
        super.tearDown()
    }

    // AC-N-02-T
    func testDateOnlyIsJSTMidnightAndRoundTrips() throws {
        let date = try XCTUnwrap(APIDateFormat.dateOnly(from: "2026-08-20"))

        var jst = Calendar(identifier: .gregorian)
        jst.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let comps = jst.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.day, 20)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.second, 0)

        XCTAssertEqual(APIDateFormat.dateOnlyString(from: date), "2026-08-20")
    }

    // AC-N-03-T: 端末 TZ が JST でなくても往復が壊れない
    func testDateOnlyRoundTripUnderForeignDeviceTimeZone() throws {
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        for raw in ["2026-01-01", "2026-08-20", "2026-12-31"] {
            let date = try XCTUnwrap(APIDateFormat.dateOnly(from: raw))
            XCTAssertEqual(APIDateFormat.dateOnlyString(from: date), raw)
        }
    }

    func testDateOnlyRejectsMalformedInput() {
        XCTAssertNil(APIDateFormat.dateOnly(from: ""))
        XCTAssertNil(APIDateFormat.dateOnly(from: "2026-08"))
        XCTAssertNil(APIDateFormat.dateOnly(from: "2026/08/20"))
        XCTAssertNil(APIDateFormat.dateOnly(from: "2026-13-01"))
        XCTAssertNil(APIDateFormat.dateOnly(from: "2026-08-20T00:00:00Z"))
    }

    // AC-N-04-T
    func testDateTimeAcceptsFractionalAndPlainSeconds() throws {
        let withFraction = try XCTUnwrap(APIDateFormat.dateTime(from: "2026-07-31T12:05:00.000Z"))
        let withoutFraction = try XCTUnwrap(APIDateFormat.dateTime(from: "2026-07-31T12:05:00Z"))
        XCTAssertEqual(withFraction, withoutFraction)
        XCTAssertEqual(withFraction.timeIntervalSince1970, 1_785_499_500, accuracy: 0.001)
    }

    func testDateTimeAcceptsOffsetForm() throws {
        let utc = try XCTUnwrap(APIDateFormat.dateTime(from: "2026-07-31T12:05:00Z"))
        let jst = try XCTUnwrap(APIDateFormat.dateTime(from: "2026-07-31T21:05:00+09:00"))
        XCTAssertEqual(utc, jst)
    }

    func testDateTimeStringIsISO8601UTCWithMilliseconds() {
        let date = Date(timeIntervalSince1970: 1_785_499_500)
        XCTAssertEqual(APIDateFormat.dateTimeString(from: date), "2026-07-31T12:05:00.000Z")
    }

    func testDateTimeRejectsMalformedInput() {
        XCTAssertNil(APIDateFormat.dateTime(from: "2026-07-31"))
        XCTAssertNil(APIDateFormat.dateTime(from: ""))
    }
}
