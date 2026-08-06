import XCTest
@testable import Domain

/// AC-N-08-T: `.unchanged` はキーごと省略され、`.set(nil)` は `null` を出力する
final class PatchableTests: XCTestCase {
    private struct SamplePatchBody: Encodable {
        var name: Patchable<String> = .unchanged
        var note: Patchable<String> = .unchanged
        var feeYen: Patchable<Int> = .unchanged

        enum CodingKeys: String, CodingKey {
            case name
            case note
            case feeYen = "fee_yen"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodePatch(name, forKey: .name)
            try c.encodePatch(note, forKey: .note)
            try c.encodePatch(feeYen, forKey: .feeYen)
        }
    }

    private func json(_ body: SamplePatchBody) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(body), as: UTF8.self)
    }

    func testUnchangedOmitsKeyEntirely() throws {
        XCTAssertEqual(try json(SamplePatchBody()), "{}")
    }

    func testSetNilEncodesExplicitNull() throws {
        var body = SamplePatchBody()
        body.note = .set(nil)
        XCTAssertEqual(try json(body), #"{"note":null}"#)
    }

    func testSetValueEncodesValue() throws {
        var body = SamplePatchBody()
        body.name = .set("A")
        body.feeYen = .set(4000)
        XCTAssertEqual(try json(body), #"{"fee_yen":4000,"name":"A"}"#)
    }

    func testMixedStates() throws {
        var body = SamplePatchBody()
        body.name = .set("A")
        body.feeYen = .set(nil)
        // note は unchanged なのでキーごと出ない
        XCTAssertEqual(try json(body), #"{"fee_yen":null,"name":"A"}"#)
    }

    func testEmptyStringIsNotCollapsedToNull() throws {
        var body = SamplePatchBody()
        body.note = .set("")
        XCTAssertEqual(try json(body), #"{"note":""}"#)
    }

    func testSetNilAndUnchangedAreDifferentValues() {
        XCTAssertNotEqual(Patchable<String>.unchanged, .set(nil))
    }
}
