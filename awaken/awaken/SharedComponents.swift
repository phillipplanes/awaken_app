import SwiftUI

// MARK: - Haptic Effect Data

struct HapticEffect: Identifiable {
    let id: UInt8
    let name: String
    let icon: String
}

let wakeEffects: [HapticEffect] = [
    HapticEffect(id: 1,   name: "Big Energy",   icon: "bolt.fill"),
    HapticEffect(id: 16,  name: "Wake Boost",   icon: "waveform"),
    HapticEffect(id: 47,  name: "Calmness",     icon: "wind"),
    HapticEffect(id: 52,  name: "Heartbeat",    icon: "heart.fill"),
    HapticEffect(id: 64,  name: "Momentum",     icon: "chart.line.uptrend.xyaxis"),
    HapticEffect(id: 118, name: "Sunrise Flow", icon: "sunrise.fill"),
    HapticEffect(id: 124, name: "Sine Ramp",    icon: "waveform.path"),
]

let testEffects: [HapticEffect] = [
    HapticEffect(id: 1,   name: "Big Energy",   icon: "bolt.fill"),
    HapticEffect(id: 10,  name: "Double Spark", icon: "bolt.horizontal.fill"),
    HapticEffect(id: 12,  name: "Triple Spark", icon: "bolt.horizontal.fill"),
    HapticEffect(id: 14,  name: "Soft Landing", icon: "hand.tap"),
    HapticEffect(id: 16,  name: "Wake Boost",   icon: "waveform"),
    HapticEffect(id: 27,  name: "Quick Charge", icon: "waveform"),
    HapticEffect(id: 47,  name: "Calmness",     icon: "wind"),
    HapticEffect(id: 52,  name: "Power Pulse",  icon: "heart.fill"),
    HapticEffect(id: 58,  name: "Concentration", icon: "metronome"),
    HapticEffect(id: 64,  name: "Momentum",     icon: "chart.line.uptrend.xyaxis"),
    HapticEffect(id: 70,  name: "Wind Down",    icon: "chart.line.downtrend.xyaxis"),
    HapticEffect(id: 118, name: "Sunrise Flow", icon: "sunrise.fill"),
    HapticEffect(id: 124, name: "Sine Ramp",    icon: "waveform.path"),
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
