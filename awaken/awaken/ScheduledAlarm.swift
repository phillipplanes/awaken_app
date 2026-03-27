import Foundation

struct ScheduledAlarm: Identifiable, Codable, Equatable {
    var id: UUID
    var hour: Int          // 0-23
    var minute: Int        // 0-59
    var repeatDays: Set<Int>  // 1=Sun..7=Sat (Calendar.component(.weekday))
    var wakeEffect: UInt8
    var alarmType: String     // AlarmType.rawValue
    var voiceOption: String   // VoiceOption.rawValue
    var audioOutput: String   // AlarmAudioOutput.rawValue
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        hour: Int,
        minute: Int,
        repeatDays: Set<Int> = [],
        wakeEffect: UInt8 = 1,
        alarmType: String = "focus",
        voiceOption: String = "shimmer",
        audioOutput: String = "phone",
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays
        self.wakeEffect = wakeEffect
        self.alarmType = alarmType
        self.voiceOption = voiceOption
        self.audioOutput = audioOutput
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    var displayTime: String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        return String(format: "%d:%02d %@", h, minute, period)
    }

    var repeatDaysSummary: String {
        if repeatDays.isEmpty { return "One-time" }
        if repeatDays.count == 7 { return "Every day" }
        if repeatDays == Set([2,3,4,5,6]) { return "Weekdays" }
        if repeatDays == Set([1,7]) { return "Weekends" }
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let ordered = [2,3,4,5,6,7,1].filter { repeatDays.contains($0) }
        return ordered.map { dayNames[$0] }.joined(separator: ", ")
    }

    /// Build a Date for the next fire time from now.
    func nextFireDate(after now: Date = Date()) -> Date {
        let calendar = Calendar.current
        for dayOffset in 0..<8 {
            guard let candidate = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: candidate)
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard let target = calendar.date(from: components) else { continue }
            if target <= now { continue }
            if repeatDays.isEmpty { return target }
            let weekday = calendar.component(.weekday, from: target)
            if repeatDays.contains(weekday) { return target }
        }
        // Fallback: tomorrow at this time
        return calendar.date(byAdding: .day, value: 1, to: now)!
    }

    // MARK: - Persistence

    private static let storageKey = "com.awaken.scheduledAlarms"

    static func loadAll() -> [ScheduledAlarm] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let alarms = try? JSONDecoder().decode([ScheduledAlarm].self, from: data) else {
            return []
        }
        return alarms.sorted { $0.hour * 60 + $0.minute < $1.hour * 60 + $1.minute }
    }

    static func saveAll(_ alarms: [ScheduledAlarm]) {
        if let data = try? JSONEncoder().encode(alarms) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
