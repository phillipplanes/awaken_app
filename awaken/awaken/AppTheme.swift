import SwiftUI
import Combine

class AppTheme: ObservableObject {
    enum Mode: String {
        case light, dark
    }

    @Published var mode: Mode

    init() {
        let saved = UserDefaults.standard.string(forKey: "appThemeMode") ?? "dark"
        self.mode = Mode(rawValue: saved) ?? .dark
    }

    func toggle() {
        mode = isDark ? .light : .dark
        UserDefaults.standard.set(mode.rawValue, forKey: "appThemeMode")
    }

    var isDark: Bool { mode == .dark }

    // MARK: - Core palette
    // Dark: royal blue base with white + gold/yellow accents
    // Light: unchanged

    var accent: Color {
        isDark ? Color(red: 0.85, green: 0.68, blue: 0.20) : Color(red: 0.35, green: 0.60, blue: 0.54)
    }
    var accentDeep: Color {
        isDark ? Color(red: 0.72, green: 0.55, blue: 0.12) : Color(red: 0.24, green: 0.46, blue: 0.41)
    }
    var accentText: Color {
        isDark ? Color(red: 0.06, green: 0.08, blue: 0.18) : Color.white
    }
    var accentSoft: Color {
        isDark ? Color(red: 0.12, green: 0.18, blue: 0.40) : Color(red: 0.84, green: 0.90, blue: 0.87)
    }
    var warmBase: Color {
        isDark ? Color(red: 0.06, green: 0.08, blue: 0.18) : Color(red: 0.96, green: 0.95, blue: 0.93)
    }
    var warmBaseDeep: Color {
        isDark ? Color(red: 0.03, green: 0.05, blue: 0.12) : Color(red: 0.91, green: 0.89, blue: 0.86)
    }
    var warmPaper: Color {
        isDark ? Color(red: 0.08, green: 0.10, blue: 0.22) : Color(red: 0.985, green: 0.98, blue: 0.965)
    }
    var cardStroke: Color {
        isDark ? Color(red: 0.16, green: 0.22, blue: 0.45) : Color(red: 0.86, green: 0.84, blue: 0.80)
    }
    var warmHighlight: Color {
        isDark ? Color(red: 0.90, green: 0.72, blue: 0.22) : Color(red: 0.94, green: 0.84, blue: 0.67)
    }
    var controlFill: Color {
        isDark ? Color(red: 0.10, green: 0.14, blue: 0.30) : Color(red: 0.93, green: 0.92, blue: 0.89)
    }
    var textPrimary: Color {
        isDark ? Color.white : Color(red: 0.26, green: 0.31, blue: 0.29)
    }
    var textSecondary: Color {
        isDark ? Color(red: 0.70, green: 0.75, blue: 0.90) : Color(red: 0.45, green: 0.50, blue: 0.47)
    }
    var successTint: Color {
        isDark ? Color(red: 0.40, green: 0.80, blue: 0.50) : Color(red: 0.43, green: 0.63, blue: 0.54)
    }
    var cautionTint: Color {
        isDark ? Color(red: 0.88, green: 0.70, blue: 0.18) : Color(red: 0.79, green: 0.57, blue: 0.40)
    }
    var dangerTint: Color {
        isDark ? Color(red: 0.90, green: 0.35, blue: 0.35) : Color(red: 0.69, green: 0.41, blue: 0.40)
    }
}
