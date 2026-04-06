import SwiftUI
import AVKit

struct ConnectedView: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @ObservedObject var weatherViewModel: AlarmWeatherViewModel
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var appState: AppState

    @Binding var alarmAudioOutput: AlarmAudioOutput
    @Binding var showTestSection: Bool
    @State private var showSettings = false
    @State private var showAlarmEditor = false
    @State private var editorAlarmTime = Date()
    @State private var editorRepeatDays: Set<Int> = []
    @State private var editorWakeEffect: UInt8 = 1
    @State private var editorAlarmType: AlarmType = .focus
    @State private var editorVoiceOption: VoiceOption = .shimmer
    @State private var editorAudioOutput: AlarmAudioOutput = .phone
    @State private var editorEditingID: UUID?

    var isConnected: Bool {
        let status = viewModel.connectionStatus
        return status == "Connected" || status == "Discovering services..."
            || status.hasPrefix("Reconnecting...") || status == "Connecting..."
    }

    var body: some View {
        NavigationView {
            connectedScrollView
        }
    }

    private var connectedScrollView: some View {
        ScrollView {
            connectedContent
                .padding(.horizontal)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle("AWAKEN")
        .toolbar { connectedToolbar }
        .sheet(isPresented: $showSettings) {
            SettingsView { appState.onboardingComplete = false }
                .environmentObject(theme)
        }
        .sheet(isPresented: $showAlarmEditor) {
            alarmEditorSheet
        }
        .safeAreaInset(edge: .bottom) {
            if viewModel.alarmFiring || viewModel.localAlarmFallbackActive {
                AlarmQuickActionsBar(viewModel: viewModel, voiceMessageViewModel: voiceMessageViewModel)
            }
        }
        .onAppear { applyAlarmAudioOutput() }
        .onChange(of: viewModel.connectionStatus) { _, newStatus in
            if newStatus == "Connected" { applyAlarmAudioOutput() }
        }
        .onChange(of: alarmAudioOutput) { _, _ in applyAlarmAudioOutput() }
        .onChange(of: viewModel.alarmFiring) { _, firing in
            handleAlarmVisibilityChange(firing || viewModel.localAlarmFallbackActive)
        }
        .onChange(of: viewModel.localAlarmFallbackActive) { _, fallback in
            handleAlarmVisibilityChange(viewModel.alarmFiring || fallback)
        }
    }

    private var alarmEditorSheet: some View {
        AlarmEditorView(
            viewModel: viewModel,
            voiceMessageViewModel: voiceMessageViewModel,
            weatherViewModel: weatherViewModel,
            alarmTime: editorAlarmTime,
            repeatDays: editorRepeatDays,
            selectedWakeEffect: editorWakeEffect,
            alarmType: editorAlarmType,
            voiceOption: editorVoiceOption,
            alarmAudioOutput: editorAudioOutput,
            editingID: editorEditingID
        )
        .environmentObject(theme)
    }

    private var connectedContent: some View {
        VStack(spacing: 16) {
            clockWeatherRow
            AlarmVerificationBanner(viewModel: viewModel)
            addAlarmButton
            ScheduledAlarmsListCard(
                viewModel: viewModel,
                voiceMessageViewModel: voiceMessageViewModel,
                onEdit: { alarm in openEditor(for: alarm) }
            )
            AudioRouteCard(viewModel: viewModel)
            DiagnosticsToolsCard(
                viewModel: viewModel,
                voiceMessageViewModel: voiceMessageViewModel,
                alarmAudioOutput: alarmAudioOutput,
                showTestSection: $showTestSection,
                isConnected: isConnected
            )
            disconnectButton
        }
    }

    private var clockWeatherRow: some View {
        VStack(spacing: 4) {
            Text(Date.now, style: .time)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(theme.textPrimary)

            if weatherViewModel.currentAvailable {
                HStack(spacing: 6) {
                    Image(systemName: weatherViewModel.currentSymbol)
                        .font(.subheadline)
                        .foregroundColor(theme.accent)
                    Text("\(weatherViewModel.currentTemp), \(weatherViewModel.currentCondition)")
                        .font(.subheadline)
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .onAppear {
            weatherViewModel.refreshCurrentWeather()
        }
    }

    private var addAlarmButton: some View {
        Button { openEditor(for: nil) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("New Alarm")
                    .fontWeight(.semibold)
            }
            .font(.title3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [theme.accent, theme.accentDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundColor(theme.accentText)
            .cornerRadius(14)
            .shadow(color: theme.accent.opacity(0.22), radius: 16, x: 0, y: 10)
        }
    }

    private var disconnectButton: some View {
        Button { viewModel.disconnect() } label: {
            Text("Disconnect")
                .font(.subheadline)
                .foregroundColor(theme.dangerTint)
        }
        .padding(.top, 4)
        .padding(.bottom, 24)
    }

    @ToolbarContentBuilder
    private var connectedToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showSettings = true } label: {
                Image(systemName: "person.crop.circle")
                    .foregroundColor(theme.textSecondary)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button { withAnimation { theme.toggle() } } label: {
                Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                    .foregroundColor(theme.isDark ? theme.warmHighlight : theme.accentDeep)
            }
        }
    }

    private func handleAlarmVisibilityChange(_ visible: Bool) {
        if visible {
            // Always play alarm audio from the phone — if A2DP is connected,
            // iOS automatically routes it to the Bluetooth speaker.
            voiceMessageViewModel.playAlarmAudioIfAvailable()
        } else {
            voiceMessageViewModel.stopAlarmAudio()
        }
    }

    private func applyAlarmAudioOutput() {
        viewModel.setAlarmSoundEnabled(alarmAudioOutput == .deviceSpeaker)
        if alarmAudioOutput == .deviceSpeaker {
            voiceMessageViewModel.stopAlarmAudio()
        }
    }

    private func openEditor(for alarm: ScheduledAlarm?) {
        if let alarm {
            let calendar = Calendar.current
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = alarm.hour
            components.minute = alarm.minute
            components.second = 0
            editorAlarmTime = calendar.date(from: components) ?? Date()
            editorRepeatDays = alarm.repeatDays
            editorWakeEffect = alarm.wakeEffect
            editorAlarmType = AlarmType(rawValue: alarm.alarmType) ?? .focus
            editorVoiceOption = VoiceOption(rawValue: alarm.voiceOption) ?? .shimmer
            editorAudioOutput = AlarmAudioOutput(rawValue: alarm.audioOutput) ?? .phone
            editorEditingID = alarm.id
        } else {
            editorAlarmTime = Date()
            editorRepeatDays = []
            editorWakeEffect = 1
            editorAlarmType = .focus
            editorVoiceOption = .shimmer
            editorAudioOutput = alarmAudioOutput
            editorEditingID = nil
        }
        showAlarmEditor = true
    }
}

// MARK: - Section Views

struct AlarmVerificationBanner: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        if !viewModel.liveAlarmVerificationMessage.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: viewModel.hasVerifiedLiveAlarm ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(viewModel.hasVerifiedLiveAlarm ? theme.accent : theme.warmHighlight)
                Text(viewModel.liveAlarmVerificationMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.accentDeep)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(viewModel.hasVerifiedLiveAlarm ? theme.accentSoft : theme.warmHighlight.opacity(0.35))
            .cornerRadius(12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct ScheduledAlarmsListCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme
    let onEdit: (ScheduledAlarm) -> Void

    var body: some View {
        if !viewModel.scheduledAlarms.isEmpty {
            SectionCard {
                Label("Alarms", systemImage: "alarm.waves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.textSecondary)

                ForEach(viewModel.scheduledAlarms) { alarm in
                    alarmRow(alarm)
                }
            }
        }
    }

    private func alarmRow(_ alarm: ScheduledAlarm) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.displayTime)
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundColor(alarm.isEnabled ? theme.textPrimary : theme.textSecondary)
                Text(alarm.repeatDaysSummary)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()

            Button { onEdit(alarm) } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .foregroundColor(theme.accent.opacity(0.7))
            }

            Toggle("", isOn: Binding(
                get: { alarm.isEnabled },
                set: { _ in viewModel.toggleAlarm(alarm) }
            ))
            .labelsHidden()
            .tint(theme.accent)

            Button(role: .destructive) {
                voiceMessageViewModel.stopAlarmAudio()
                viewModel.deleteAlarm(alarm)
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title3)
                    .foregroundColor(theme.dangerTint.opacity(0.7))
            }
        }
        .padding(.vertical, 6)
        .opacity(alarm.isEnabled ? 1 : 0.5)
    }
}

struct TestVibrationCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme
    @Binding var showTestSection: Bool
    @State private var intensityDebounce: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $showTestSection) {
                VStack(spacing: 14) {
                    intensitySection
                    effectsGrid
                }
                .padding(.top, 12)
            } label: {
                Label("Test Vibration", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.textSecondary)
            }
            .tint(theme.textSecondary)
        }
    }

    private var intensitySection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Intensity").font(.subheadline)
                Spacer()
                Text("\(Int(viewModel.vibrationIntensity))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(theme.textSecondary)
                Button("Stop") {
                    viewModel.vibrationIntensity = 0
                    viewModel.stopVibration()
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(theme.dangerTint)
                .padding(.leading, 8)
            }
            Slider(value: $viewModel.vibrationIntensity, in: 0...100, step: 1)
                .tint(theme.accent)
                .onChange(of: viewModel.vibrationIntensity) { _, newValue in
                    intensityDebounce?.cancel()
                    let work = DispatchWorkItem { viewModel.setVibrationIntensity(newValue) }
                    intensityDebounce = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                }
        }
    }

    private var effectsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(testEffects) { effect in
                Button { viewModel.playEffect(effect.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: effect.icon).font(.caption)
                        Text(effect.name).font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(theme.controlFill)
                    .foregroundColor(theme.textPrimary)
                    .cornerRadius(8)
                }
            }
        }
    }
}

struct SpeakerCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme
    let alarmAudioOutput: AlarmAudioOutput
    @State private var speakerDebounce: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speaker", systemImage: "speaker.wave.2")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            Text(
                alarmAudioOutput == .deviceSpeaker
                    ? "These controls affect the onboard speaker."
                    : "Phone output ignores device speaker volume."
            )
            .font(.caption)
            .foregroundColor(theme.textSecondary)

            speakerVolumeSection
            testFrequencySection
            testToneButton
        }
    }

    private var speakerVolumeSection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Volume").font(.subheadline)
                Spacer()
                Text("\(Int(viewModel.speakerVolume))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(theme.textSecondary)
            }
            Slider(value: $viewModel.speakerVolume, in: 0...100, step: 1)
                .tint(theme.accent)
                .onChange(of: viewModel.speakerVolume) { _, newValue in
                    speakerDebounce?.cancel()
                    let work = DispatchWorkItem { viewModel.setSpeakerVolume(newValue) }
                    speakerDebounce = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                }
                .disabled(alarmAudioOutput != .deviceSpeaker)
        }
    }

    private var testFrequencySection: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Test Frequency").font(.subheadline)
                Spacer()
                Text("\(Int(viewModel.testToneFrequency)) Hz")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(theme.textSecondary)
            }
            Slider(value: $viewModel.testToneFrequency, in: 300...2400, step: 10)
                .tint(theme.accent)
        }
    }

    private var testToneButton: some View {
        Button {
            viewModel.playSpeakerTestTone()
        } label: {
            Label("Play Test Tone", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(theme.controlFill)
                .cornerRadius(10)
        }
        .foregroundColor(theme.textPrimary)
    }
}

struct DeviceStatusCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Device", systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            statusRow(
                present: viewModel.hasSpeakerAmp,
                label: "MAX98357A Amp",
                presentText: "Ready",
                missingText: "Not Ready"
            )
            statusRow(
                present: viewModel.hasDRV2605L,
                label: "Haptic Driver",
                presentText: "Connected",
                missingText: "Not Found"
            )

            HStack(spacing: 10) {
                Image(systemName: viewModel.batteryLevelPercent == nil ? "battery.25" : "battery.75")
                    .foregroundColor(viewModel.batteryLevelPercent == nil ? theme.cautionTint : theme.successTint)
                Text("Battery").font(.subheadline)
                Spacer()
                Text(viewModel.batteryStatusText)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }
        }
    }

    private func statusRow(present: Bool, label: String, presentText: String, missingText: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(present ? theme.successTint : theme.dangerTint)
            Text(label).font(.subheadline)
            Spacer()
            Text(present ? presentText : missingText)
                .font(.caption)
                .foregroundColor(theme.textSecondary)
        }
    }
}

struct ConnectionStatusCard: View {
    @EnvironmentObject private var theme: AppTheme
    let isConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connection Status", systemImage: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 10) {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isConnected ? theme.successTint : theme.dangerTint)
                Text("BLE (AWAKEN-manage)").font(.subheadline)
                Spacer()
                Text(isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }
        }
    }
}

struct DiagnosticsToolsCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme
    let alarmAudioOutput: AlarmAudioOutput
    @Binding var showTestSection: Bool
    let isConnected: Bool
    @State private var isExpanded = false

    var body: some View {
        SectionCard {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 16) {
                    TestVibrationCard(viewModel: viewModel, showTestSection: $showTestSection)
                    SpeakerCard(
                        viewModel: viewModel,
                        voiceMessageViewModel: voiceMessageViewModel,
                        alarmAudioOutput: alarmAudioOutput
                    )
                    DeviceStatusCard(viewModel: viewModel)
                    ConnectionStatusCard(isConnected: isConnected)
                }
                .padding(.top, 8)
            } label: {
                Label("Diagnostics Tools", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.textSecondary)
            }
            .tint(theme.textSecondary)
        }
    }
}

struct AlarmQuickActionsBar: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        HStack(spacing: 10) {
            Button {
                voiceMessageViewModel.stopAlarmAudio()
                viewModel.snoozeAlarm()
            } label: {
                Label("Snooze", systemImage: "zzz")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(theme.warmHighlight)
                    .cornerRadius(12)
            }
            .foregroundColor(theme.accentText)

            Button {
                voiceMessageViewModel.stopAlarmAudio()
                viewModel.stopAlarm()
            } label: {
                Label("Shut Off", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(theme.accentSoft.opacity(0.85))
                    .cornerRadius(12)
            }
            .foregroundColor(theme.accentDeep)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(theme.warmPaper.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.cardStroke.opacity(0.6))
                .frame(height: 1)
        }
    }
}

struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = .systemBlue
        picker.tintColor = .secondaryLabel
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct AudioRouteCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        SectionCard {
            Label("Audio Route", systemImage: "hifispeaker.2")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 10) {
                Image(systemName: viewModel.isAwakenAudioRouteActive ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(viewModel.isAwakenAudioRouteActive ? theme.successTint : theme.cautionTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.audioRouteStatus).font(.subheadline)
                    if !viewModel.isAwakenAudioRouteActive {
                        Text("Connect to AWAKEN in Bluetooth settings to play alarm audio through the pillow speaker.")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                Spacer()
            }

            AudioRoutePickerButton()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
    }
}
