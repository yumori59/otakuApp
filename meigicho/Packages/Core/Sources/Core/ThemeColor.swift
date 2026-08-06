import Foundation

public struct RGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xFF)
        g = Double((v >> 8) & 0xFF)
        b = Double(v & 0xFF)
    }

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var hexString: String {
        func c(_ v: Double) -> Int { max(0, min(255, Int(v.rounded()))) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

public struct HSL: Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var l: Double
}

public func rgbToHSL(_ c: RGB) -> HSL {
    let r = c.r / 255, g = c.g / 255, b = c.b / 255
    let mx = max(r, g, b), mn = min(r, g, b)
    let l = (mx + mn) / 2
    guard mx != mn else { return HSL(h: 0, s: 0, l: l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
    else if mx == g { h = (b - r) / d + 2 }
    else { h = (r - g) / d + 4 }
    return HSL(h: h / 6, s: s, l: l)
}

public func hslToRGB(_ c: HSL) -> RGB {
    guard c.s != 0 else { return RGB(r: c.l * 255, g: c.l * 255, b: c.l * 255) }
    func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    let q = c.l < 0.5 ? c.l * (1 + c.s) : c.l + c.s - c.l * c.s
    let p = 2 * c.l - q
    return RGB(
        r: hue2rgb(p, q, c.h + 1.0 / 3) * 255,
        g: hue2rgb(p, q, c.h) * 255,
        b: hue2rgb(p, q, c.h - 1.0 / 3) * 255
    )
}

public func mixHex(_ a: String, _ b: String, _ t: Double) -> String {
    let x = RGB(hex: a), y = RGB(hex: b)
    return RGB(
        r: x.r + (y.r - x.r) * t,
        g: x.g + (y.g - x.g) * t,
        b: x.b + (y.b - x.b) * t
    ).hexString
}

public func ensureDarkEnough(_ hex: String, maxLightness: Double = 0.34) -> String {
    var hsl = rgbToHSL(RGB(hex: hex))
    hsl.l = min(hsl.l, maxLightness)
    return hslToRGB(hsl).hexString
}

public func relativeLuminance(_ c: RGB) -> Double {
    func lin(_ v: Double) -> Double {
        let s = v / 255
        return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let la = relativeLuminance(a), lb = relativeLuminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

public func accessibleOnWhite(_ hex: String, minRatio: Double = 4.5, startL: Double = 0.34) -> String {
    var hsl = rgbToHSL(RGB(hex: hex))
    hsl.l = min(hsl.l, startL)
    let white = RGB(hex: "#FFFFFF")
    while hsl.l > 0.02, contrastRatio(hslToRGB(hsl), white) < minRatio {
        hsl.l -= 0.02
    }
    return hslToRGB(hsl).hexString
}
