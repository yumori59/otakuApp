import XCTest
@testable import Core

/// AC-N-01-T: UUIDv7.generate() が version=7 / variant=0b10 のビットを持ち、
/// 同一ミリ秒内で単調増加する。
final class UUIDv7Tests: XCTestCase {
    func testVersionAndVariantBits() {
        for _ in 0..<200 {
            let uuid = UUIDv7.generate()
            let bytes = uuid.uuid
            XCTAssertEqual(bytes.6 >> 4, 0x7, "version nibble must be 7")
            XCTAssertEqual(bytes.8 >> 6, 0b10, "variant bits must be 0b10")
        }
    }

    func testMonotonicWithinSameMillisecond() {
        let fixed = Date(timeIntervalSince1970: 1_785_000_000.123)
        var previous = UUIDv7.generate(date: fixed)
        for _ in 0..<500 {
            let next = UUIDv7.generate(date: fixed)
            let previousSeq = Self.sequence(of: previous)
            let nextSeq = Self.sequence(of: next)
            // 同一ミリ秒内は 12bit カウンタが 1 ずつ進む
            XCTAssertEqual(nextSeq, (previousSeq + 1) & 0x0FFF)
            if nextSeq != 0 {
                // カウンタが一周していない限り、バイト列としても単調増加する
                XCTAssertTrue(
                    Self.isAscending(previous, next),
                    "\(previous) should sort before \(next)"
                )
            }
            previous = next
        }
    }

    private static func sequence(of uuid: UUID) -> UInt16 {
        let u = uuid.uuid
        return (UInt16(u.6 & 0x0F) << 8) | UInt16(u.7)
    }

    func testTimestampRoundTrip() {
        let fixed = Date(timeIntervalSince1970: 1_785_000_000.123)
        let uuid = UUIDv7.generate(date: fixed)
        let recovered = UUIDv7.timestamp(of: uuid)
        XCTAssertEqual(recovered.timeIntervalSince1970, 1_785_000_000.123, accuracy: 0.001)
    }

    func testTimestampOrderingAcrossMilliseconds() {
        let early = UUIDv7.generate(date: Date(timeIntervalSince1970: 1_785_000_000))
        let late = UUIDv7.generate(date: Date(timeIntervalSince1970: 1_785_000_001))
        XCTAssertTrue(Self.isAscending(early, late))
    }

    private static func isAscending(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let a = bytes(of: lhs)
        let b = bytes(of: rhs)
        for i in 0..<16 where a[i] != b[i] {
            return a[i] < b[i]
        }
        return false
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}
