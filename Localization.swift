import Foundation

enum L10n {
    static let supported = ["en", "zh-Hans", "zh-Hant"]
    static func resolve(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first ?? "en"
    }
    static let language = resolve(Locale.preferredLanguages)
    static func resourceBundle(_ language: String) -> Bundle {
        guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            fatalError("Missing localization resources: \(language)")
        }
        return bundle
    }
    static let bundle = resourceBundle(language)
    static func validateResources() {
        assert(resolve(["en-US"]) == "en")
        assert(resolve(["zh-CN"]) == "zh-Hans")
        assert(resolve(["zh-TW"]) == "zh-Hant")
        assert(resolve(["zh-HK"]) == "zh-Hant")
        assert(resolve(["fr-FR"]) == "en")
        assert(resolve(["fr-FR", "zh-Hans", "en"]) == "zh-Hans")
        var reference: [String: String] = [:]
        for language in supported {
            let bundle = resourceBundle(language)
            let url = bundle.url(forResource: "Localizable", withExtension: "strings")!
            let values = NSDictionary(contentsOf: url) as! [String: String]
            if language == "en" { reference = values }
            assert(Set(values.keys) == Set(reference.keys))
            for (key, value) in values {
                assert(!value.isEmpty)
                assert(value.components(separatedBy: "%@").count == reference[key]!.components(separatedBy: "%@").count)
            }
            assert(bundle.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist") != "NSMicrophoneUsageDescription")
        }
        print("PASS: English, Simplified/Traditional Chinese, fallback and format parity")
    }
}
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let value = L10n.bundle.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? value : String(format: value, locale: Locale(identifier: L10n.language), arguments: arguments)
}
