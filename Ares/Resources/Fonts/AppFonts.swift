import SwiftUI
import CoreText

extension Font {
    /// Inter with an arbitrary weight value (100–900). Supports any value thanks to the variable font.
    /// Example: `.inter(weight: 450, size: 13)` for something between Regular and Medium.
    static func inter(weight: CGFloat = 400, size: CGFloat) -> Font {
        let desc = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: "Inter Variable",
            kCTFontTraitsAttribute: [
                kCTFontWeightTrait: (weight - 400) / 500
            ]
        ] as CFDictionary)
        let ctFont = CTFontCreateWithFontDescriptor(desc, size, nil)
        return Font(ctFont)
    }

    /// Blender Pro with named weights.
    static func blender(_ style: BlenderStyle = .book, size: CGFloat) -> Font {
        Font.custom(style.postScriptName, size: size)
    }

    enum BlenderStyle {
        case thin, book, medium, bold

        var postScriptName: String {
            switch self {
            case .thin:   return "BlenderTrial-Thin"
            case .book:   return "BlenderTrial-Book"
            case .medium: return "BlenderTrial-Medium"
            case .bold:   return "BlenderTrial-Bold"
            }
        }
    }
}
