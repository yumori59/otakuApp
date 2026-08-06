import Foundation

/// 同一公演への複数申込を検知する（`docs/01` R2-8 / C4）。**ブロックはしない**（代表者入替の意図的重複を許容）。
public enum DuplicateApplicationDetection {
    public static func duplicateEventIDs(in applications: [ApplicationEntry]) -> Set<UUID> {
        var counts: [UUID: Int] = [:]
        for application in applications {
            counts[application.eventID, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.map(\.key))
    }

    public static func coApplications(for eventID: UUID, in applications: [ApplicationEntry]) -> [ApplicationEntry] {
        applications.filter { $0.eventID == eventID }
    }
}
