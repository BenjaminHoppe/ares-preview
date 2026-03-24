import AppKit
import CoreText

enum FontRegistration {
    static func registerAll() {
        let fontFiles = [
            "InterVariable.ttf",
            "InterVariable-Italic.ttf",
            "BlenderTrial-Thin.otf",
            "BlenderTrial-Book.otf",
            "BlenderTrial-Medium.otf",
            "BlenderTrial-Bold.otf",
        ]
        for file in fontFiles {
            let ext = (file as NSString).pathExtension
            let name = (file as NSString).deletingPathExtension
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                continue
            }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }
}
