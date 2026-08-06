import Foundation
import Domain
import Core

extension IdentityRecord {
    /// `POST /v1/sync/push` 用の snake_case payload。
    public func syncPayload() -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "display_name": .string(displayName),
            "relation": .string(relationRaw),
            "color": .string(colorHex),
            "history_visible": .bool(historyVisible),
            "sort_order": .number(Double(sortOrder)),
            "note": note.isEmpty ? .null : .string(note),
        ]
        if let joinedOn {
            payload["joined_on"] = .string(APIDateFormat.dateOnlyString(from: joinedOn))
        } else {
            payload["joined_on"] = .null
        }
        if let deletedAt {
            payload["deleted_at"] = .string(APIDateFormat.dateTimeString(from: deletedAt))
        } else {
            payload["deleted_at"] = .null
        }
        return payload
    }

    public static func parseRemote(_ object: [String: JSONValue]) -> (
        id: UUID,
        displayName: String,
        relationRaw: String,
        colorHex: String,
        joinedOn: Date?,
        note: String,
        historyVisible: Bool,
        sortOrder: Int,
        updatedAt: Date,
        deletedAt: Date?
    )? {
        guard let idString = object["id"]?.stringValue,
              let id = UUID(uuidString: idString),
              let displayName = object["display_name"]?.stringValue,
              let relationRaw = object["relation"]?.stringValue,
              let colorHex = object["color"]?.stringValue,
              let updatedAtString = object["updated_at"]?.stringValue,
              let updatedAt = APIDateFormat.dateTime(from: updatedAtString)
        else { return nil }

        let joinedOn = object["joined_on"]?.stringValue.flatMap(APIDateFormat.dateOnly)
        let note = object["note"]?.stringValue ?? ""
        let historyVisible = object["history_visible"].flatMap { value -> Bool? in
            if case .bool(let flag) = value { return flag }
            return nil
        } ?? false
        let sortOrder = object["sort_order"]?.intValue ?? 0
        let deletedAt = object["deleted_at"]?.stringValue.flatMap(APIDateFormat.dateTime)

        return (
            id,
            displayName,
            relationRaw,
            colorHex,
            joinedOn,
            note,
            historyVisible,
            sortOrder,
            updatedAt,
            deletedAt
        )
    }
}
