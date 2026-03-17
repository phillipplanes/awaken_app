//
//  awakenApp.swift
//  awaken
//
//  Created by Phillip planes on 2/7/26.
//

import SwiftUI

@main
struct awakenApp: App {
    init() {
        AlarmNotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
        }
    }
}
