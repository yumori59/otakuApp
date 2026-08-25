import Foundation

/// **Preview / テスト専用のサンプルデータ**（Q5）。
/// 実行時の画面は `InMemory*Repository` 経由でのみこれを見る。
/// BE 接続後（T1〜T4b）は `Remote*Repository` に差し替わり、実行時には一切出なくなる。
public enum SampleData {
    public static let referenceDate = date(2026, 7, 31)

    // MARK: - ID

    public static let identity1 = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let identity2 = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    public static let identity3 = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    public static let identity4 = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!

    private static let tour1 = UUID(uuidString: "00000000-0000-4000-8000-000000000201")!
    private static let tour2 = UUID(uuidString: "00000000-0000-4000-8000-000000000202")!
    private static let tour3 = UUID(uuidString: "00000000-0000-4000-8000-000000000203")!
    private static let tour4 = UUID(uuidString: "00000000-0000-4000-8000-000000000204")!
    private static let tour5 = UUID(uuidString: "00000000-0000-4000-8000-000000000205")!
    private static let tour6 = UUID(uuidString: "00000000-0000-4000-8000-000000000206")!

    private static let event1 = UUID(uuidString: "00000000-0000-4000-8000-000000000301")!
    private static let event2 = UUID(uuidString: "00000000-0000-4000-8000-000000000302")!
    private static let event3 = UUID(uuidString: "00000000-0000-4000-8000-000000000303")!
    private static let event4 = UUID(uuidString: "00000000-0000-4000-8000-000000000304")!
    private static let event5 = UUID(uuidString: "00000000-0000-4000-8000-000000000305")!
    private static let event6 = UUID(uuidString: "00000000-0000-4000-8000-000000000306")!
    private static let event7 = UUID(uuidString: "00000000-0000-4000-8000-000000000307")!

    // MARK: - 名義

    public static let identities: [Identity] = [
        Identity(
            id: identity1,
            displayName: "佐藤 (自分)",
            relation: .self,
            colorHex: "#0017C1",
            joinedOn: date(2023, 4, 2),
            historyVisible: true,
            note: "メインで使っている名義。基本的にはこれで申し込む。",
            sortOrder: 0,
            updatedAt: referenceDate
        ),
        Identity(
            id: identity2,
            displayName: "佐藤 陽菜 (妹)",
            relation: .family,
            colorHex: "#3460FB",
            joinedOn: date(2024, 1, 15),
            historyVisible: true,
            note: "遠征に同行することが多い。年会費はこちらで負担。",
            sortOrder: 1,
            updatedAt: referenceDate
        ),
        Identity(
            id: identity3,
            displayName: "田中 美咲 (友人)",
            relation: .friend,
            colorHex: "#5C5C6B",
            joinedOn: date(2024, 11, 20),
            historyVisible: false,
            note: "ORBITの申込みで名義を借りている。当選時は事前に連絡する。",
            sortOrder: 2,
            updatedAt: referenceDate
        ),
        Identity(
            id: identity4,
            displayName: "小林 蓮 (友人)",
            relation: .friend,
            colorHex: "#45454F",
            joinedOn: date(2025, 6, 8),
            historyVisible: false,
            sortOrder: 3,
            updatedAt: referenceDate
        ),
    ]

    // MARK: - 会員情報（会員番号は全桁を保持・表示する）

    public static let memberships: [Membership] = [
        Membership(id: uuid(0x401), identityID: identity1, fanClubNameRaw: "STELLARIS OFFICIAL FAN CLUB",
                   memberNo: "STL-04821", renewalOn: date(2026, 11, 3), feeYen: 4000),
        Membership(id: uuid(0x402), identityID: identity1, fanClubNameRaw: "ORBIT native club",
                   memberNo: "ORB-01239", renewalOn: date(2027, 2, 14), feeYen: 3500),
        Membership(id: uuid(0x403), identityID: identity2, fanClubNameRaw: "STELLARIS OFFICIAL FAN CLUB",
                   memberNo: "STL-09931", renewalOn: date(2026, 8, 19), feeYen: 4000),
        Membership(id: uuid(0x404), identityID: identity3, fanClubNameRaw: "ORBIT native club",
                   memberNo: "ORB-02984", renewalOn: date(2026, 9, 5), feeYen: 3500),
        Membership(id: uuid(0x405), identityID: identity4, fanClubNameRaw: "陽炎 (Kagerou) Fan Club",
                   memberNo: "KGR-00567", renewalOn: date(2026, 12, 1), feeYen: 5000),
    ]

    // MARK: - ツアー / 公演

    public static let tours: [Tour] = [
        Tour(id: tour1, name: "STELLARIS ARENA TOUR 2026", artistNameRaw: "STELLARIS", updatedAt: referenceDate),
        Tour(id: tour2, name: "ORBIT 5th Anniversary LIVE", artistNameRaw: "ORBIT", updatedAt: referenceDate),
        Tour(id: tour3, name: "陽炎 冬コンサート 2026", artistNameRaw: "陽炎", updatedAt: referenceDate),
        Tour(id: tour4, name: "ORBIT native club限定イベント -春の一夜-", artistNameRaw: "ORBIT", updatedAt: referenceDate),
        Tour(id: tour5, name: "STELLARIS 春の一夜 スペシャルイベント", artistNameRaw: "STELLARIS", updatedAt: referenceDate),
        Tour(id: tour6, name: "STELLARIS ファンミーティング Vol.3", artistNameRaw: "STELLARIS", updatedAt: referenceDate),
    ]

    public static let events: [EventEntity] = [
        EventEntity(id: event1, tourID: tour1, name: "STELLARIS ARENA TOUR 2026 -大阪公演-",
                    venueNameRaw: "大阪城ホール", eventDate: date(2026, 9, 27), updatedAt: referenceDate),
        EventEntity(id: event2, tourID: tour1, name: "STELLARIS ARENA TOUR 2026 -東京公演-",
                    venueNameRaw: "さいたまスーパーアリーナ", eventDate: date(2026, 9, 13), updatedAt: referenceDate),
        EventEntity(id: event3, tourID: tour2, name: "ORBIT 5th Anniversary LIVE",
                    venueNameRaw: "横浜アリーナ", eventDate: date(2026, 8, 30), updatedAt: referenceDate),
        EventEntity(id: event4, tourID: tour3, name: "陽炎 冬コンサート 2026",
                    venueNameRaw: "日本武道館", eventDate: date(2026, 12, 20), updatedAt: referenceDate),
        EventEntity(id: event5, tourID: tour4, name: "ORBIT native club限定イベント -春の一夜-",
                    venueNameRaw: "Zepp Haneda", eventDate: date(2026, 8, 9), updatedAt: referenceDate),
        EventEntity(id: event6, tourID: tour5, name: "STELLARIS 春の一夜 スペシャルイベント",
                    venueNameRaw: "幕張メッセ", eventDate: date(2026, 5, 18), updatedAt: referenceDate),
        EventEntity(id: event7, tourID: tour6, name: "STELLARIS ファンミーティング Vol.3",
                    venueNameRaw: "東京国際フォーラム", eventDate: date(2026, 10, 4), updatedAt: referenceDate),
    ]

    // MARK: - 申込

    public static let applications: [ApplicationEntry] = [
        ApplicationEntry(
            id: uuid(0x101), tourID: tour1, eventID: event1, repIdentityID: identity1,
            appliedOn: date(2026, 7, 1), resultOn: date(2026, 8, 5), status: .applied,
            companions: [Companion(id: uuid(0x501), identityID: identity2, displayName: "佐藤 陽菜(妹)", position: 0)],
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x109), tourID: tour1, eventID: event1, repIdentityID: identity2,
            appliedOn: date(2026, 7, 1), resultOn: date(2026, 8, 5), status: .applied,
            companions: [Companion(id: uuid(0x502), identityID: identity1, displayName: "佐藤 (自分)", position: 0)],
            note: "同じ公演を代表者/同行者を入れ替えて重複申込",
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x102), tourID: tour1, eventID: event2, repIdentityID: identity2,
            appliedOn: date(2026, 6, 20), resultOn: date(2026, 7, 15), status: .won,
            seatRaw: "アリーナ8列15番", updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x103), tourID: tour2, eventID: event3, repIdentityID: identity3,
            appliedOn: date(2026, 6, 25), resultOn: date(2026, 7, 10), status: .lost,
            companions: [Companion(id: uuid(0x503), identityID: identity1, displayName: "佐藤 (自分)", position: 0)],
            note: "当選していたら自分が同行する予定だった",
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x104), tourID: tour3, eventID: event4, repIdentityID: identity4,
            appliedOn: date(2026, 8, 5), resultOn: date(2026, 9, 10), status: .applied,
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x105), tourID: tour4, eventID: event5, repIdentityID: identity1,
            appliedOn: date(2026, 6, 1), resultOn: date(2026, 6, 20), status: .won,
            seatRaw: "2階 B-12, B-13",
            companions: [Companion(id: uuid(0x504), identityID: identity2, displayName: "佐藤 陽菜(妹)", position: 0)],
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x106), tourID: tour5, eventID: event6, repIdentityID: identity1,
            appliedOn: date(2026, 3, 1), resultOn: date(2026, 3, 25), status: .lost,
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x107), tourID: tour4, eventID: event5, repIdentityID: identity3,
            appliedOn: date(2026, 6, 1), resultOn: date(2026, 6, 20), status: .lost,
            note: "自分名義の方が当選したため未使用",
            updatedAt: referenceDate
        ),
        ApplicationEntry(
            id: uuid(0x108), tourID: tour6, eventID: event7, repIdentityID: identity2,
            appliedOn: date(2026, 8, 1), resultOn: date(2026, 8, 25), status: .applied,
            updatedAt: referenceDate
        ),
    ]

    // MARK: - プロフィール / 権利

    public static let profile = UserProfile(
        userID: uuid(0x001),
        accountID: "ACC-1A2B3C",
        displayName: nil,
        username: nil,
        appDisplayName: nil,
        themeColor: "#0017C1",
        locale: "ja-JP",
        timezone: "Asia/Tokyo",
        onboardedAt: referenceDate,
        email: nil,
        authProviders: []
    )

    public static let entitlement = Entitlement(plan: .free, identityLimit: 10, shareLimit: 1)

    // MARK: - Helper

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", suffix))!
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}
