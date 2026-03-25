import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = BluetoothViewModel()
    @StateObject private var weatherViewModel = AlarmWeatherViewModel()
    @StateObject private var voiceMessageViewModel = VoiceMessageViewModel()
    @State private var alarmTime = Date()
    @State private var alarmType: AlarmType = .focus
    @State private var voiceOption: VoiceOption = .shimmer
    @State private var selectedWakeEffect: UInt8 = 1
    @State private var alarmAudioOutput: AlarmAudioOutput = .phone
    @State private var repeatDays: Set<Int> = []
    @State private var showTestSection = false
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var appState: AppState

    var isConnected: Bool {
        let status = viewModel.connectionStatus
        return status == "Connected" || status == "Discovering services..."
            || status.hasPrefix("Reconnecting...") || status == "Connecting..."
    }

    var isAlarmAlertVisible: Bool {
        viewModel.alarmFiring || viewModel.localAlarmFallbackActive
    }

    var body: some View {
        ZStack {
            SpaBackground()
                .ignoresSafeArea()

            if isConnected {
                ConnectedView(
                    viewModel: viewModel,
                    voiceMessageViewModel: voiceMessageViewModel,
                    weatherViewModel: weatherViewModel,
                    alarmTime: $alarmTime,
                    alarmType: $alarmType,
                    voiceOption: $voiceOption,
                    selectedWakeEffect: $selectedWakeEffect,
                    alarmAudioOutput: $alarmAudioOutput,
                    repeatDays: $repeatDays,
                    showTestSection: $showTestSection
                )
            } else {
                ScanningView(viewModel: viewModel)
            }

            if isAlarmAlertVisible {
                AlarmOverlayView(
                    viewModel: viewModel,
                    voiceMessageViewModel: voiceMessageViewModel
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .animation(.easeInOut(duration: 0.3), value: isAlarmAlertVisible)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
