import SwiftUI
import Core

@Observable
public final class ThemeStore: @unchecked Sendable {
    public private(set) var seedHex = "#0017C1"
    public private(set) var primary = DS.Blue.b900
    public private(set) var primaryHover = DS.Blue.b1000
    public private(set) var primaryTint = DS.Blue.b50
    public private(set) var bgApp = DS.Gray.g50
    public private(set) var surfaceAlt = DS.Gray.g100

    public init() {
        if let saved = UserDefaults.standard.string(forKey: "theme.seedHex") {
            apply(hex: saved)
        }
    }

    public func apply(hex: String) {
        seedHex = hex
        primary = Color(hexString: accessibleOnWhite(hex, startL: 0.34))
        primaryHover = Color(hexString: accessibleOnWhite(hex, startL: 0.24))
        primaryTint = Color(hexString: mixHex("#FFFFFF", hex, 0.14))
        bgApp = Color(hexString: mixHex("#FFFFFF", hex, 0.05))
        surfaceAlt = Color(hexString: mixHex("#FFFFFF", hex, 0.08))
        UserDefaults.standard.set(hex, forKey: "theme.seedHex")
    }
}

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = ThemeStore()
}

public extension EnvironmentValues {
    var themeStore: ThemeStore {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}
