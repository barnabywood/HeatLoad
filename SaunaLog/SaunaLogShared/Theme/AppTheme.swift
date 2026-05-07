import SwiftUI

public enum AppTheme {
    public static let charcoal = Color(red: 0.06, green: 0.07, blue: 0.09)   // #0F1115
    public static let ember = Color(red: 0.89, green: 0.34, blue: 0.18)      // #E4572E
    public static let steam = Color(red: 0.18, green: 0.55, blue: 0.60)      // #2E8C99
    public static let sand = Color(red: 0.96, green: 0.94, blue: 0.90)       // #F4EFE6

    public static let card = Color(red: 0.09, green: 0.10, blue: 0.13)

    public static var hairline: Color { .white.opacity(0.13) }

    public static var iOSBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.09),
                Color(red: 0.16, green: 0.12, blue: 0.11)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var watchBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.01, green: 0.01, blue: 0.02),
                Color(red: 0.03, green: 0.03, blue: 0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    public static func titleFont(_ size: CGFloat) -> Font {
        .custom("AvenirNext-DemiBold", size: size)
    }

    public static func bodyFont(_ size: CGFloat) -> Font {
        .custom("AvenirNext-Regular", size: size)
    }

    public static func accentFont(_ size: CGFloat) -> Font {
        .custom("AvenirNext-Medium", size: size)
    }
}
