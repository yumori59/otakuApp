import Foundation

public enum AvatarColors {
    public static let palette = [
        "#0017C1", "#3460FB", "#5C5C6B", "#264AF4", "#45454F", "#00118F", "#7B7B89",
    ]

    public static func defaultColor(index: Int) -> String {
        palette[index % palette.count]
    }
}
