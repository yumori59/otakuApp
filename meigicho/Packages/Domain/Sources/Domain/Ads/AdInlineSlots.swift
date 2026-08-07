import Foundation

/// 申込一覧（リスト）でネイティブ広告を差し込む**行位置**を決める純粋型（F2-3 / `docs/07` §7.2）。
///
/// 「5件目の後、以降10件ごと、1画面あたり2枚まで」というルールは View に書くと検証できないので
/// `Domain` の純粋関数に寄せる（`.claude/rules/01-aidlc.md` / plan.md §4 D2 と同じ方針）。
///
/// 返す値は「**その index の行の直後**に 1 枚差し込む」を意味する 0-origin の行インデックス。
/// - 5 件未満は空配列（E13。1 画面目に広告を出さないための下限そのものが満たせない）
/// - 上限 2 枚（F2-3）。`AdGatekeeper` の F4-1 / F4-3 は別途 `AdsStore` 側で効く
///
/// **注意（F2-3 と F4-3 の相互作用）**: 現行の `AdGatekeeper` は F4-3「同一画面で連続 2 枚を
/// 出さない」を `lastShownPlacement == placement` で表す（AC-AD-25）。申込一覧の 2 枠は
/// どちらも `.applicationsInline` なので、**実際に描画されるのは 1 枚目だけ**になる。
/// つまり本型が返す 2 件目の位置は「枠を置く位置」であって「必ず出る位置」ではない。
/// 2 枚出したい場合は F4-3 の解釈（同一面で二度と出さない → 隣接して出さない）を
/// 仕様として決め直す必要があるため、ここでは意図的に現状維持としている。
public enum AdInlineSlots: Sendable {
    /// 最初の差し込み位置 = 5 件目の後（0-origin で 4 の行の直後）。
    public static let firstIndex = 4
    /// 2 枚目以降の間隔（10 件ごと）。
    public static let interval = 10
    /// 1 画面あたりの上限枚数。
    public static let maxPerScreen = 2

    /// `itemCount` 件のリストに対する広告の差し込み位置。
    public static func adPositions(itemCount: Int) -> [Int] {
        guard itemCount > firstIndex else { return [] }
        return Array(stride(from: firstIndex, to: itemCount, by: interval).prefix(maxPerScreen))
    }

    /// `index` 行目の直後に広告を差し込むか。
    public static func shouldInsertAd(afterIndex index: Int, itemCount: Int) -> Bool {
        adPositions(itemCount: itemCount).contains(index)
    }
}
