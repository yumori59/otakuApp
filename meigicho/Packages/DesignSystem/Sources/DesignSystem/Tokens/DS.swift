import SwiftUI

public enum DS {
    public enum Blue {
        public static let b50 = Color(hex: 0xE8F1FE)
        public static let b100 = Color(hex: 0xD9E6FF)
        public static let b900 = Color(hex: 0x0017C1)
        public static let b1000 = Color(hex: 0x00118F)
    }

    public enum Gray {
        public static let g50 = Color(hex: 0xF7F7F9)
        public static let g100 = Color(hex: 0xEEEEF2)
        public static let g200 = Color(hex: 0xE1E1E7)
        public static let g300 = Color(hex: 0xC9C9D2)
        public static let g400 = Color(hex: 0x9C9CA8)
        public static let g500 = Color(hex: 0x7B7B89)
        public static let g600 = Color(hex: 0x5C5C6B)
        public static let g900 = Color(hex: 0x18181C)
    }

    public static let success = Color(hex: 0x177A46)
    public static let successBG = Color(hex: 0xE3F3EA)
    public static let error = Color(hex: 0xC21F39)
    public static let errorBG = Color(hex: 0xFBE7EA)
    public static let warning = Color(hex: 0xA15C00)
    public static let warningBG = Color(hex: 0xFBEBD9)

    public static let surface = Color.white

    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
    }

    public enum Space {
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 24
    }
}

public enum DSFont {
    public static let bigTitle = Font.system(size: 28, weight: .bold)
    public static let bodyBold = Font.system(size: 16, weight: .bold)
    public static let body = Font.system(size: 16, weight: .regular)
    public static let caption = Font.system(size: 14, weight: .regular)
    public static let captionBold = Font.system(size: 14, weight: .bold)
    public static let mono = Font.system(size: 14, weight: .regular, design: .monospaced)
    public static let statNum = Font.system(size: 24, weight: .bold, design: .monospaced)
}
