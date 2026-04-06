import SwiftUI

// MARK: - Haptic Effect Data

struct HapticEffect: Identifiable {
    let id: UInt8
    let name: String
    let icon: String
}

let wakeEffects: [HapticEffect] = [
    HapticEffect(id: 1, name: "Light",  icon: "wind"),
    HapticEffect(id: 2, name: "Medium", icon: "waveform"),
    HapticEffect(id: 3, name: "Heavy",  icon: "bolt.fill"),
]

let testEffects: [HapticEffect] = [
    HapticEffect(id: 1, name: "Light",  icon: "wind"),
    HapticEffect(id: 2, name: "Medium", icon: "waveform"),
    HapticEffect(id: 3, name: "Heavy",  icon: "bolt.fill"),
]

// MARK: - Alarm Audio Output

enum AlarmAudioOutput: String, CaseIterable, Identifiable {
    case phone
    case deviceSpeaker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone: return "Phone"
        case .deviceSpeaker: return "Device"
        }
    }

    var description: String {
        switch self {
        case .phone:
            return "Play the generated voice through this phone while the app stays connected."
        case .deviceSpeaker:
            return "Upload the generated voice to AWAKEN and let the device play it directly, even if the phone is locked."
        }
    }
}

// MARK: - Section Card

struct SectionCard<Content: View>: View {
    @EnvironmentObject private var theme: AppTheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .background(theme.warmPaper)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(theme.cardStroke.opacity(0.95), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: theme.accent.opacity(0.06), radius: 16, x: 0, y: 10)
    }
}

// MARK: - Spa Background

struct SpaBackground: View {
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.warmPaper, theme.warmBase, theme.warmBaseDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(theme.accentSoft.opacity(0.7))
                .frame(width: 280, height: 280)
                .blur(radius: 28)
                .offset(x: 140, y: -210)

            Circle()
                .fill(theme.warmHighlight.opacity(0.28))
                .frame(width: 240, height: 240)
                .blur(radius: 36)
                .offset(x: -150, y: 260)

            Circle()
                .fill(theme.warmPaper.opacity(0.9))
                .frame(width: 210, height: 210)
                .blur(radius: 18)
                .offset(x: -120, y: -300)
        }
    }
}
