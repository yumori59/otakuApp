import Foundation

/// UUID v7 の生成。
/// 主キーはクライアント発行 UUID v7（`docs/03` ADR / `docs/05` §2.4）。
/// 実装は `docs/05-ios-client.md` §2.4 のコードをそのまま採用している。
public enum UUIDv7 {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMillis: UInt64 = 0
    nonisolated(unsafe) private static var counter: UInt16 = 0

    public static func generate(date: Date = Date()) -> UUID {
        let ms = UInt64((date.timeIntervalSince1970 * 1000).rounded(.down))
        lock.lock()
        if ms == lastMillis { counter &+= 1 } else { lastMillis = ms; counter = UInt16.random(in: 0...0x0FFF) }
        let seq = counter & 0x0FFF
        lock.unlock()
        var b = [UInt8](repeating: 0, count: 16)
        // 0-5: unix_ts_ms（48bit big endian）
        b[0] = UInt8((ms >> 40) & 0xFF); b[1] = UInt8((ms >> 32) & 0xFF); b[2] = UInt8((ms >> 24) & 0xFF)
        b[3] = UInt8((ms >> 16) & 0xFF); b[4] = UInt8((ms >> 8) & 0xFF);  b[5] = UInt8(ms & 0xFF)
        // 6-7: version(0b0111) + rand_a に同一 ms 内カウンタを載せ、単調性を保つ
        b[6] = 0x70 | UInt8((seq >> 8) & 0x0F); b[7] = UInt8(seq & 0xFF)
        // 8-15: variant(0b10) + rand_b(62bit)
        var rng = SystemRandomNumberGenerator()
        for i in 8..<16 { b[i] = UInt8.random(in: 0...255, using: &rng) }
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// 生成時刻の復元（デバッグ・移行検証用）
    public static func timestamp(of uuid: UUID) -> Date {
        let u = uuid.uuid
        let ms = (UInt64(u.0) << 40) | (UInt64(u.1) << 32) | (UInt64(u.2) << 24)
            | (UInt64(u.3) << 16) | (UInt64(u.4) << 8) | UInt64(u.5)
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}
