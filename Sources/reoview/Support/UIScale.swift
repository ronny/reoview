import SwiftUI

/// How much larger than macOS default this app draws its text and icons.
///
/// macOS has no Dynamic Type for third-party apps. The text size control in
/// System Settings, Accessibility, applies only to the Apple apps listed
/// beside it, and SwiftUI's `dynamicTypeSize` follows no system setting on
/// macOS. There is nothing to read, so the scale is a setting of this app and
/// every size that has to grow with it goes through this type. Semantic fonts
/// such as `.body` and `.caption` are fixed sizes on macOS, so they are spelled
/// out here as the point sizes macOS gives them.
struct UIScale: Equatable, Sendable {
    static let unscaled = UIScale(1)

    let factor: CGFloat

    init(_ factor: Double) {
        self.factor = CGFloat(AppConfig.clampedUIScale(factor))
    }

    /// A font, given the size it has at scale 1.
    func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * factor, weight: weight)
    }

    /// A frame side, padding, or spacing, given the length it has at scale 1.
    func length(_ points: CGFloat) -> CGFloat {
        points * factor
    }
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue = UIScale.unscaled
}

extension EnvironmentValues {
    var uiScale: UIScale {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}
