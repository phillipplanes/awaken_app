import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = BluetoothViewModel()
    @StateObject private var weatherViewModel = AlarmWeatherViewModel()
    @StateObject private var voiceMessageViewModel = VoiceMessageViewModel()
    @State private var alarmAudioOutput: AlarmAudioOutput = .phone
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
                    alarmAudioOutput: $alarmAudioOutput,
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
