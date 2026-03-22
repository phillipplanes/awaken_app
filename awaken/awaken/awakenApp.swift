import SwiftUI
import Combine

@main
struct awakenApp: App {
    @StateObject private var theme = AppTheme()
    @StateObject private var appState = AppState()

    init() {
        AlarmNotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.onboardingComplete {
                    ContentView()
                } else {
                    OnboardingView(isComplete: $appState.onboardingComplete)
                }
            }
            .environmentObject(theme)
            .environmentObject(appState)
            .preferredColorScheme(theme.isDark ? .dark : .light)
        }
    }
}

class AppState: ObservableObject {
    @Published var onboardingComplete: Bool

    init() {
        self.onboardingComplete = UserProfile.load().onboardingComplete
    }
}
