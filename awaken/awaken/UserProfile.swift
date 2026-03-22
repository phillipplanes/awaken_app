import Foundation

struct UserProfile: Codable {
    var firstName: String = ""
    var motivations: Set<String> = []
    var stressors: Set<String> = []
    var onboardingComplete: Bool = false

    static let motivationOptions = [
        "Family & loved ones",
        "Career growth",
        "Health & fitness",
        "Financial freedom",
        "Creative expression",
        "Learning & knowledge",
        "Helping others",
        "Adventure & travel",
        "Inner peace",
        "Building something meaningful"
    ]

    static let stressorOptions = [
        "Work deadlines",
        "Money & finances",
        "Health concerns",
        "Relationship issues",
        "Lack of sleep",
        "Social pressure",
        "Uncertainty about the future",
        "Feeling overwhelmed",
        "Not enough time",
        "Loneliness"
    ]

    // MARK: - Persistence

    private static let storageKey = "com.awaken.userProfile"

    static func load() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return UserProfile()
        }
        return profile
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    var promptContext: String {
        var parts: [String] = []
        if !firstName.isEmpty {
            parts.append("The user's name is \(firstName).")
        }
        if !motivations.isEmpty {
            parts.append("They are motivated by: \(motivations.sorted().joined(separator: ", ")).")
        }
        if !stressors.isEmpty {
            parts.append("They deal with stress from: \(stressors.sorted().joined(separator: ", ")).")
        }
        return parts.joined(separator: " ")
    }
}
