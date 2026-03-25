import SwiftUI

struct ConnectedView: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @ObservedObject var weatherViewModel: AlarmWeatherViewModel
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var appState: AppState

    @Binding var alarmTime: Date
    @Binding var alarmType: AlarmType
    @Binding var voiceOption: VoiceOption
    @Binding var selectedWakeEffect: UInt8
    @Binding var alarmAudioOutput: AlarmAudioOutput
    @Binding var repeatDays: Set<Int>
    @Binding var showTestSection: Bool
    @State private var showSettings = false

    var isConnected: Bool {
        let status = viewModel.connectionStatus
        return status == "Connected" || status == "Discovering services..."
            || status.hasPrefix("Reconnecting...") || status == "Connecting..."
    }

    var isAlarmVisible: Bool {
        viewModel.alarmFiring || viewModel.localAlarmFallbackActive
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    AlarmVerificationBanner(viewModel: viewModel)
                    AlarmTimeCard(
                        viewModel: viewModel,
                        weatherViewModel: weatherViewModel,
                        alarmTime: $alarmTime,
                        repeatDays: $repeatDays,
                        alarmAudioOutput: alarmAudioOutput
                    )
                    WakeUpPatternCard(viewModel: viewModel, selectedWakeEffect: $selectedWakeEffect)
                    VoiceMessageCard(
                        viewModel: viewModel,
                        voiceMessageViewModel: voiceMessageViewModel,
                        alarmTime: alarmTime,
                        alarmType: $alarmType,
                        voiceOption: $voiceOption,
                        alarmAudioOutput: alarmAudioOutput,
                        weatherSummary: "\(weatherViewModel.forecastText). \(weatherViewModel.detailText)"
                    )
                    AlarmAudioCard(viewModel: viewModel, alarmAudioOutput: $alarmAudioOutput)
                    AudioRouteCard(viewModel: viewModel)
                    SetAlarmButton { handleSetAlarm() }
                    ScheduledAlarmCard(viewModel: viewModel, voiceMessageViewModel: voiceMessageViewModel)
                    TestVibrationCard(viewModel: viewModel, showTestSection: $showTestSection)
                    SpeakerCard(
                        viewModel: viewModel,
                        voiceMessageViewModel: voiceMessageViewModel,
                        alarmAudioOutput: alarmAudioOutput
                    )
                    DeviceStatusCard(viewModel: viewModel)
                    ConnectionStatusCard(isConnected: isConnected)
                    Button {
                        viewModel.disconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.subheadline)
                            .foregroundColor(theme.dangerTint)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("AWAKEN")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(theme.textSecondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation { theme.toggle() }
                    } label: {
                        Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                            .foregroundColor(theme.isDark ? theme.warmHighlight : theme.accentDeep)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView {
                    appState.onboardingComplete = false
                }
                .environmentObject(theme)
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.alarmFiring || viewModel.localAlarmFallbackActive {
                    AlarmQuickActionsBar(viewModel: viewModel, voiceMessageViewModel: voiceMessageViewModel)
                }
            }
            .onAppear {
                weatherViewModel.scheduleRefresh(for: alarmTime)
                applyAlarmAudioOutput()
            }
            .onChange(of: alarmTime) { _, newValue in
                weatherViewModel.scheduleRefresh(for: newValue)
            }
            .onChange(of: viewModel.connectionStatus) { _, newStatus in
                if newStatus == "Connected" {
                    applyAlarmAudioOutput()
                }
            }
            .onChange(of: alarmAudioOutput) { _, _ in
                applyAlarmAudioOutput()
            }
            .onChange(of: isAlarmVisible) { _, isVisible in
                if isVisible {
                    if alarmAudioOutput == .phone {
                        voiceMessageViewModel.playAlarmAudioIfAvailable()
                    } else {
                        voiceMessageViewModel.stopAlarmAudio()
                    }
                } else {
                    voiceMessageViewModel.stopAlarmAudio()
                }
            }
        }
    }

    private func applyAlarmAudioOutput() {
        viewModel.setAlarmSoundEnabled(alarmAudioOutput == .deviceSpeaker)
        if alarmAudioOutput == .deviceSpeaker {
            voiceMessageViewModel.stopAlarmAudio()
        }
    }

    private func handleSetAlarm() {
        applyAlarmAudioOutput()
        let days = repeatDays
        if alarmAudioOutput == .deviceSpeaker,
           let pcmData = voiceMessageViewModel.devicePCMData, !pcmData.isEmpty {
            let time = alarmTime
            let effect = selectedWakeEffect
            let rate = voiceMessageViewModel.devicePCMSampleRate
            viewModel.syncDeviceAlarmAudio(pcmData, sampleRate: rate) { _ in
                viewModel.setAlarm(time: time, repeatDays: days)
                viewModel.setWakeEffect(effect)
            }
        } else {
            viewModel.setAlarm(time: alarmTime, repeatDays: days)
            viewModel.setWakeEffect(selectedWakeEffect)
        }
    }

    private func handleSyncToDevice() {
        guard let pcmData = voiceMessageViewModel.devicePCMData, !pcmData.isEmpty else { return }
        let rate = voiceMessageViewModel.devicePCMSampleRate
        viewModel.syncDeviceAlarmAudio(pcmData, sampleRate: rate) { _ in }
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

struct AlarmTimeCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var weatherViewModel: AlarmWeatherViewModel
    @EnvironmentObject private var theme: AppTheme
    @Binding var alarmTime: Date
    @Binding var repeatDays: Set<Int>
    let alarmAudioOutput: AlarmAudioOutput

    var body: some View {
        SectionCard {
            Label("Alarm Time", systemImage: "alarm")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            DatePicker("", selection: $alarmTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.wheel)
                .dynamicTypeSize(.accessibility5)
                .scaleEffect(x: 1.6, y: 1.6)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .colorScheme(theme.isDark ? .dark : .light)
                .background(theme.warmPaper)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(theme.cardStroke.opacity(0.9), lineWidth: 1)
                )
                .environment(\.colorScheme, .light)

            HStack(spacing: 6) {
                repeatDayButton(day: 2, label: "M")
                repeatDayButton(day: 3, label: "T")
                repeatDayButton(day: 4, label: "W")
                repeatDayButton(day: 5, label: "T")
                repeatDayButton(day: 6, label: "F")
                repeatDayButton(day: 7, label: "S")
                repeatDayButton(day: 1, label: "S")
            }
            .frame(maxWidth: .infinity)

            if !repeatDays.isEmpty {
                Text(repeatDaysSummary)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: weatherViewModel.symbolName)
                    .font(.title3)
                    .foregroundColor(theme.accent)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(weatherViewModel.forecastText)
                        .font(.subheadline.weight(.medium))
                    Text(weatherViewModel.detailText)
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()

                if weatherViewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await weatherViewModel.refreshNow(for: alarmTime) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundColor(theme.textSecondary)
            }
        }
    }

    private func repeatDayButton(day: Int, label: String) -> some View {
        Button {
            if repeatDays.contains(day) {
                repeatDays.remove(day)
            } else {
                repeatDays.insert(day)
            }
        } label: {
            Text(label)
                .font(.caption.weight(.bold))
                .frame(width: 36, height: 36)
                .background(repeatDays.contains(day) ? theme.accent : theme.controlFill)
                .foregroundColor(repeatDays.contains(day) ? .white : theme.textSecondary)
                .clipShape(Circle())
        }
    }

    private var repeatDaysSummary: String {
        if repeatDays.count == 7 { return "Every day" }
        if repeatDays == Set([2,3,4,5,6]) { return "Weekdays" }
        if repeatDays == Set([1,7]) { return "Weekends" }
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let ordered = [2,3,4,5,6,7,1].filter { repeatDays.contains($0) }
        return ordered.map { dayNames[$0] }.joined(separator: ", ")
    }
}

struct WakeUpPatternCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme
    @Binding var selectedWakeEffect: UInt8

    var body: some View {
        SectionCard {
            Label("Wake-Up Pattern", systemImage: "waveform.path")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            Text("Choose the vibration style the alarm will use")
                .font(.caption)
                .foregroundColor(theme.textSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(wakeEffects) { effect in
                    Button {
                        selectedWakeEffect = effect.id
                        viewModel.setWakeEffect(effect.id)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: effect.icon)
                                .font(.title3)
                            Text(effect.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedWakeEffect == effect.id ? theme.accent.opacity(0.12) : theme.controlFill)
                        .foregroundColor(selectedWakeEffect == effect.id ? theme.accent : theme.textPrimary)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedWakeEffect == effect.id ? theme.accent : Color.clear, lineWidth: 1.5)
                        )
                    }
                }
            }
        }
    }
}

struct VoiceMessageCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme
    let alarmTime: Date
    @Binding var alarmType: AlarmType
    @Binding var voiceOption: VoiceOption
    let alarmAudioOutput: AlarmAudioOutput
    let weatherSummary: String

    var body: some View {
        SectionCard {
            Label("Voice Message", systemImage: "mic.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            Picker("Alarm Type", selection: $alarmType) {
                ForEach(AlarmType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .pickerStyle(.segmented)

            Picker("Voice", selection: $voiceOption) {
                ForEach(VoiceOption.allCases) { voice in
                    Text(voice.title).tag(voice)
                }
            }

            Text(voiceMessageViewModel.status.label)
                .font(.caption)
                .foregroundColor(theme.textSecondary)

            if !voiceMessageViewModel.scriptText.isEmpty {
                Text(voiceMessageViewModel.scriptText)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(theme.controlFill)
                    .cornerRadius(10)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await voiceMessageViewModel.generate(
                            alarmType: alarmType,
                            alarmTime: alarmTime,
                            weatherSummary: weatherSummary,
                            voice: voiceOption.rawValue
                        )
                    }
                } label: {
                    Label("AI Generate", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.controlFill)
                        .cornerRadius(10)
                }
                .foregroundColor(theme.textPrimary)

                if voiceMessageViewModel.isRecording {
                    Button {
                        voiceMessageViewModel.stopRecording()
                    } label: {
                        Label("Stop (\(voiceMessageViewModel.recordingTimeRemaining)s)", systemImage: "stop.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.2))
                            .cornerRadius(10)
                    }
                    .foregroundColor(.red)
                } else {
                    Button {
                        voiceMessageViewModel.startRecording()
                    } label: {
                        Label("Record", systemImage: "mic.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(theme.controlFill)
                            .cornerRadius(10)
                    }
                    .foregroundColor(theme.textPrimary)
                }

                Button {
                    voiceMessageViewModel.playPreview()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.controlFill)
                        .cornerRadius(10)
                }
                .foregroundColor(theme.textPrimary)
            }

            if alarmAudioOutput == .deviceSpeaker {
                HStack(spacing: 10) {
                    Button {
                        guard let pcmData = voiceMessageViewModel.devicePCMData, !pcmData.isEmpty else { return }
                        let rate = voiceMessageViewModel.devicePCMSampleRate
                        viewModel.syncDeviceAlarmAudio(pcmData, sampleRate: rate) { _ in }
                    } label: {
                        Label("Sync to Device", systemImage: "hifispeaker.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(theme.controlFill)
                            .cornerRadius(10)
                    }
                    .foregroundColor(theme.textPrimary)

                    Button {
                        viewModel.playUploadedVoiceOnDevice()
                    } label: {
                        Label("Device Play", systemImage: "play.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(theme.controlFill)
                            .cornerRadius(10)
                    }
                    .foregroundColor(theme.textPrimary)
                }
            }
        }
    }
}

struct AlarmAudioCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme
    @Binding var alarmAudioOutput: AlarmAudioOutput

    var body: some View {
        SectionCard {
            Label("Alarm Audio", systemImage: "speaker.wave.3")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            Picker("Play alarm on", selection: $alarmAudioOutput) {
                ForEach(AlarmAudioOutput.allCases) { output in
                    Text(output.title).tag(output)
                }
            }
            .pickerStyle(.segmented)

            Text(alarmAudioOutput.description)
                .font(.caption)
                .foregroundColor(theme.textSecondary)

            if alarmAudioOutput == .deviceSpeaker && !viewModel.voiceUploadStatus.isEmpty {
                Text(viewModel.voiceUploadStatus)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }
        }
    }
}

struct SetAlarmButton: View {
    @EnvironmentObject private var theme: AppTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "alarm.fill")
                Text("Set Alarm")
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
            .foregroundColor(.white)
            .cornerRadius(14)
            .shadow(color: theme.accent.opacity(0.22), radius: 16, x: 0, y: 10)
        }
    }
}

struct ScheduledAlarmCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        if let scheduledAlarmDisplayTime = viewModel.scheduledAlarmDisplayTime {
            SectionCard {
                Label("Scheduled Alarm", systemImage: "alarm.waves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.textSecondary)

                HStack {
                    Text(scheduledAlarmDisplayTime)
                        .font(.title3.monospacedDigit())
                    Spacer()
                    Button(role: .destructive) {
                        voiceMessageViewModel.stopAlarmAudio()
                        viewModel.stopAlarm()
                    } label: {
                        Text("Delete Alarm")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}

struct TestVibrationCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme
    @Binding var showTestSection: Bool
    @State private var intensityDebounce: DispatchWorkItem?

    var body: some View {
        SectionCard {
            DisclosureGroup(isExpanded: $showTestSection) {
                VStack(spacing: 14) {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Intensity")
                                .font(.subheadline)
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
                                let work = DispatchWorkItem {
                                    viewModel.setVibrationIntensity(newValue)
                                }
                                intensityDebounce = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                            }
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(testEffects) { effect in
                            Button {
                                viewModel.playEffect(effect.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: effect.icon)
                                        .font(.caption)
                                    Text(effect.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
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
                .padding(.top, 12)
            } label: {
                Label("Test Vibration", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.textSecondary)
            }
            .tint(theme.textSecondary)
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
        SectionCard {
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

            VStack(spacing: 6) {
                HStack {
                    Text("Volume")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(viewModel.speakerVolume))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(theme.textSecondary)
                }

                Slider(value: $viewModel.speakerVolume, in: 0...100, step: 1)
                    .tint(theme.accent)
                    .onChange(of: viewModel.speakerVolume) { _, newValue in
                        speakerDebounce?.cancel()
                        let work = DispatchWorkItem {
                            viewModel.setSpeakerVolume(newValue)
                        }
                        speakerDebounce = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                    }
                    .disabled(alarmAudioOutput != .deviceSpeaker)
            }

            VStack(spacing: 6) {
                HStack {
                    Text("Test Frequency")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(viewModel.testToneFrequency)) Hz")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(theme.textSecondary)
                }

                Slider(value: $viewModel.testToneFrequency, in: 300...2400, step: 10)
                    .tint(theme.accent)
            }

            Button {
                if alarmAudioOutput == .deviceSpeaker {
                    viewModel.playSpeakerTestTone()
                } else {
                    voiceMessageViewModel.playTestTone(frequencyHz: viewModel.testToneFrequency)
                }
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
}

struct DeviceStatusCard: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        SectionCard {
            Label("Device", systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 10) {
                Image(systemName: viewModel.hasSpeakerAmp ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(viewModel.hasSpeakerAmp ? theme.successTint : theme.dangerTint)
                Text("MAX98357A Amp")
                    .font(.subheadline)
                Spacer()
                Text(viewModel.hasSpeakerAmp ? "Ready" : "Not Ready")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            HStack(spacing: 10) {
                Image(systemName: viewModel.hasDRV2605L ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(viewModel.hasDRV2605L ? theme.successTint : theme.dangerTint)
                Text("Haptic Driver")
                    .font(.subheadline)
                Spacer()
                Text(viewModel.hasDRV2605L ? "Connected" : "Not Found")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            HStack(spacing: 10) {
                Image(systemName: viewModel.batteryLevelPercent == nil ? "battery.25" : "battery.75")
                    .foregroundColor(viewModel.batteryLevelPercent == nil ? theme.cautionTint : theme.successTint)
                Text("Battery")
                    .font(.subheadline)
                Spacer()
                Text(viewModel.batteryStatusText)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }
        }
    }
}

struct ConnectionStatusCard: View {
    @EnvironmentObject private var theme: AppTheme
    let isConnected: Bool

    var body: some View {
        SectionCard {
            Label("Connection Status", systemImage: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 10) {
                Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isConnected ? theme.successTint : theme.dangerTint)
                Text("BLE (AWAKEN-Control)")
                    .font(.subheadline)
                Spacer()
                Text(isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }
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
                    .background(theme.warmHighlight.opacity(0.35))
                    .cornerRadius(12)
            }
            .foregroundColor(theme.accentDeep)

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
                    Text(viewModel.audioRouteStatus)
                        .font(.subheadline)
                    if !viewModel.isAwakenAudioRouteActive {
                        Text("Connect to AWAKEN in Bluetooth settings to play alarm audio through the pillow speaker.")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                    }
                }
                Spacer()
            }

            if !viewModel.isAwakenAudioRouteActive {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Bluetooth Settings", systemImage: "gear")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.controlFill)
                        .cornerRadius(10)
                }
                .foregroundColor(theme.textPrimary)
            }
        }
    }
}
