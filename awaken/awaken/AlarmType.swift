import Foundation

enum AlarmType: String, CaseIterable, Identifiable {
    case gentle
    case focus
    case workout
    case urgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gentle:
            return "Gentle"
        case .focus:
            return "Focus"
        case .workout:
            return "Workout"
        case .urgent:
            return "Urgent"
        }
    }

    var instruction: String {
        switch self {
        case .gentle:
            return "Use a calm, reassuring tone."
        case .focus:
            return "Use a clear, determined tone for getting started."
        case .workout:
            return "Use an energetic, hype tone for movement."
        case .urgent:
            return "Use a direct, motivating tone with urgency but no panic."
        }
    }

    var voice: String {
        switch self {
        case .gentle:
            return "alloy"
        case .focus:
            return "nova"
        case .workout:
            return "fable"
        case .urgent:
            return "onyx"
        }
    }
}

enum VoiceOption: String, CaseIterable, Identifiable {
    case shimmer
    case nova
    case alloy
    case echo
    case onyx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shimmer:
            return "Shimmer (Soothing)"
        case .nova:
            return "Nova (Warm)"
        case .alloy:
            return "Alloy (Neutral)"
        case .echo:
            return "Echo (Bright)"
        case .onyx:
            return "Onyx (Deep)"
        }
    }
}
