import Foundation

public enum L10n {
    public static func string(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
