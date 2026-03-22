import SwiftUI
import CoreBluetooth
import Combine

// MARK: - Effect Data

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

enum AlarmAudioOutput: String, CaseIterable, Identifiable {
    case phone
    case deviceSpeaker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .phone:
            return "Phone"
        case .deviceSpeaker:
            return "Device"
        }
    }

    var description: String {
        switch self {
        case .phone:
            return "Play the generated voice through this phone while the app stays connected."
        case .deviceSpeaker:
            return "Upload the generated voice to Awaken and let the device play it directly, even if the phone is locked."
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var viewModel = BluetoothViewModel()
    @StateObject private var weatherViewModel = AlarmWeatherViewModel()
    @StateObject private var voiceMessageViewModel = VoiceMessageViewModel()
    @State private var alarmTime = Date()
    @State private var alarmType: AlarmType = .focus
    @State private var voiceOption: VoiceOption = .shimmer
    @State private var selectedWakeEffect: UInt8 = 1
    @State private var alarmAudioOutput: AlarmAudioOutput = .phone
    @State private var repeatDays: Set<Int> = [] // 1=Sun, 2=Mon, ..., 7=Sat
    @State private var intensityDebounce: DispatchWorkItem?
    @State private var speakerDebounce: DispatchWorkItem?
    @State private var showTestSection = false
    @State private var showSettings = false
    @EnvironmentObject private var theme: AppTheme
    @EnvironmentObject private var appState: AppState

    private var accent: Color { theme.accent }
    private var accentDeep: Color { theme.accentDeep }
    private var accentSoft: Color { theme.accentSoft }
    private var warmBase: Color { theme.warmBase }
    private var warmBaseDeep: Color { theme.warmBaseDeep }
    private var warmPaper: Color { theme.warmPaper }
    private var cardStroke: Color { theme.cardStroke }
    private var warmHighlight: Color { theme.warmHighlight }
    private var controlFill: Color { theme.controlFill }
    private var textPrimary: Color { theme.textPrimary }
    private var textSecondary: Color { theme.textSecondary }
    private var successTint: Color { theme.successTint }
    private var cautionTint: Color { theme.cautionTint }
    private var dangerTint: Color { theme.dangerTint }

    var isConnected: Bool {
        let status = viewModel.connectionStatus
        return status == "Connected" || status == "Discovering services..." || status.hasPrefix("Reconnecting...") || status == "Connecting..."
    }

    var isAlarmAlertVisible: Bool {
        viewModel.alarmFiring || viewModel.localAlarmFallbackActive
    }

    var body: some View {
        ZStack {
            spaBackground
                .ignoresSafeArea()

            if isConnected {
                connectedView
            } else {
                scanningView
            }

            if isAlarmAlertVisible {
                alarmOverlay
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .foregroundStyle(textPrimary)
        .animation(.easeInOut(duration: 0.3), value: isAlarmAlertVisible)
    }

    // MARK: - Scanning View

    var scanningView: some View {
        NavigationView {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(accentSoft.opacity(0.65))
                            .frame(width: 104, height: 104)

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 40))
                            .foregroundColor(accentDeep)
                    }

                    Text("Searching for Awaken")
                        .font(.title2.weight(.semibold))

                    Text(viewModel.connectionStatus)
                        .font(.subheadline)
                        .foregroundColor(accentDeep.opacity(0.7))

                    if viewModel.connectionStatus.contains("Scanning") {
                        ProgressView()
                            .padding(.top, 4)
                            .tint(accent)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .background(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(cardStroke.opacity(0.9), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: accent.opacity(0.08), radius: 24, x: 0, y: 14)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)

                if !viewModel.discoveredPeripherals.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DEVICES")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(accentDeep.opacity(0.7))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)

                        ForEach(viewModel.discoveredPeripherals, id: \.identifier) { peripheral in
                            Button {
                                viewModel.connect(to: peripheral)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "bed.double.fill")
                                        .font(.title3)
                                        .foregroundColor(accent)
                                        .frame(width: 36)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peripheral.name ?? "Unknown Device")
                                            .font(.body.weight(.medium))
                                            .foregroundColor(textPrimary)
                                        Text("Awaken Alarm Clock")
                                            .font(.caption)
                                            .foregroundColor(textSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(accentDeep.opacity(0.55))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                            }
                        }
                    }
                    .background(cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(cardStroke.opacity(0.9), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: accent.opacity(0.06), radius: 18, x: 0, y: 10)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("Awaken")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation { theme.toggle() }
                    } label: {
                        Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                            .foregroundColor(theme.isDark ? theme.warmHighlight : accentDeep)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { viewModel.startScanning() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .tint(accentDeep)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Connected View

    var connectedView: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // Verified live alarm banner
                    if !viewModel.liveAlarmVerificationMessage.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.hasVerifiedLiveAlarm ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(viewModel.hasVerifiedLiveAlarm ? accent : warmHighlight)
                            Text(viewModel.liveAlarmVerificationMessage)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(accentDeep)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background((viewModel.hasVerifiedLiveAlarm ? accentSoft : warmHighlight.opacity(0.35)))
                        .cornerRadius(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    sectionCard {
                        Label("Connection Status", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

                        HStack(spacing: 10) {
                            Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isConnected ? successTint : dangerTint)
                            Text("BLE (Awaken-Control)")
                                .font(.subheadline)
                            Spacer()
                            Text(isConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundColor(textSecondary)
                        }
                    }

                    // --- Alarm Time ---
                    sectionCard {
                        Label("Alarm Time", systemImage: "alarm")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

                        DatePicker("", selection: $alarmTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.wheel)
                            .dynamicTypeSize(.accessibility5)
                            .scaleEffect(x: 1.6, y: 1.6)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .colorScheme(theme.isDark ? .dark : .light)
                            .background(warmPaper)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(cardStroke.opacity(0.9), lineWidth: 1)
                            )
                            .environment(\.colorScheme, .light)

                        // Repeat days
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
                                .foregroundColor(textSecondary)
                        }

                        Divider()

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: weatherViewModel.symbolName)
                                .font(.title3)
                                .foregroundColor(accent)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(weatherViewModel.forecastText)
                                    .font(.subheadline.weight(.medium))
                                Text(weatherViewModel.detailText)
                                    .font(.caption)
                                    .foregroundColor(textSecondary)
                            }

                            Spacer()

                            if weatherViewModel.isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button {
                                Task {
                                    await weatherViewModel.refreshNow(for: alarmTime)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(textSecondary)
                        }
                    }

                    // --- Wake-Up Pattern ---
                    sectionCard {
                        Label("Wake-Up Pattern", systemImage: "waveform.path")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

                        Text("Choose the vibration style the alarm will use")
                            .font(.caption)
                            .foregroundColor(textSecondary)

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
                                    .background(
                                        selectedWakeEffect == effect.id
                                            ? accent.opacity(0.12)
                                            : controlFill
                                    )
                                    .foregroundColor(
                                        selectedWakeEffect == effect.id ? accent : textPrimary
                                    )
                                    .cornerRadius(10)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(
                                                selectedWakeEffect == effect.id ? accent : Color.clear,
                                                lineWidth: 1.5
                                            )
                                    )
                                }
                            }
                        }
                    }

                    // --- Voice Message ---
                    sectionCard {
                        Label("Voice Message", systemImage: "mic.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

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
                            .foregroundColor(textSecondary)

                        if !voiceMessageViewModel.scriptText.isEmpty {
                            Text(voiceMessageViewModel.scriptText)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(controlFill)
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
                                    .background(controlFill)
                                    .cornerRadius(10)
                            }
                            .foregroundColor(textPrimary)

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
                                        .background(controlFill)
                                        .cornerRadius(10)
                                }
                                .foregroundColor(textPrimary)
                            }

                            Button {
                                voiceMessageViewModel.playPreview()
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(controlFill)
                                    .cornerRadius(10)
                            }
                            .foregroundColor(textPrimary)
                        }

                        if alarmAudioOutput == .deviceSpeaker {
                            HStack(spacing: 10) {
                                Button {
                                    handleSyncToDevice()
                                } label: {
                                    Label("Sync to Device", systemImage: "hifispeaker.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(controlFill)
                                        .cornerRadius(10)
                                }
                                .foregroundColor(textPrimary)

                                Button {
                                    viewModel.playUploadedVoiceOnDevice()
                                } label: {
                                    Label("Device Play", systemImage: "play.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(controlFill)
                                        .cornerRadius(10)
                                }
                                .foregroundColor(textPrimary)
                            }
                        }

                    }

                    sectionCard {
                        Label("Alarm Audio", systemImage: "speaker.wave.3")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

                        Picker("Play alarm on", selection: $alarmAudioOutput) {
                            ForEach(AlarmAudioOutput.allCases) { output in
                                Text(output.title).tag(output)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(alarmAudioOutput.description)
                            .font(.caption)
                            .foregroundColor(textSecondary)

                        if alarmAudioOutput == .deviceSpeaker && !viewModel.voiceUploadStatus.isEmpty {
                            Text(viewModel.voiceUploadStatus)
                                .font(.caption)
                                .foregroundColor(textSecondary)
                        }
                    }

                    // --- Set Alarm ---
                    Button {
                        handleSetAlarm()
                    } label: {
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
                                colors: [accent, accentDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(14)
                        .shadow(color: accent.opacity(0.22), radius: 16, x: 0, y: 10)
                    }

                    if let scheduledAlarmDisplayTime = viewModel.scheduledAlarmDisplayTime {
                        sectionCard {
                            Label("Scheduled Alarm", systemImage: "alarm.waves.left.and.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(textSecondary)

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

                    // --- Test Vibration ---
                    sectionCard {
                        DisclosureGroup(isExpanded: $showTestSection) {
                            VStack(spacing: 14) {
                                // Intensity
                                VStack(spacing: 6) {
                                    HStack {
                                        Text("Intensity")
                                            .font(.subheadline)
                                        Spacer()
                                        Text("\(Int(viewModel.vibrationIntensity))%")
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundColor(textSecondary)
                                        Button("Stop") {
                                            viewModel.vibrationIntensity = 0
                                            viewModel.stopVibration()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(dangerTint)
                                        .padding(.leading, 8)
                                    }

                                    Slider(value: $viewModel.vibrationIntensity, in: 0...100, step: 1)
                                        .tint(accent)
                                        .onChange(of: viewModel.vibrationIntensity) { oldValue, newValue in
                                            intensityDebounce?.cancel()
                                            let work = DispatchWorkItem {
                                                viewModel.setVibrationIntensity(newValue)
                                            }
                                            intensityDebounce = work
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
                                        }
                                }

                                // Effects
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
                                            .background(controlFill)
                                            .foregroundColor(textPrimary)
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("Test Vibration", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(textSecondary)
                        }
                        .tint(textSecondary)
                    }

                    // --- Device ---
                    sectionCard {
                        Label("Speaker", systemImage: "speaker.wave.2")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

                        Text(
                            alarmAudioOutput == .deviceSpeaker
                                ? "These controls affect the onboard speaker."
                                : "Phone output ignores device speaker volume."
                        )
                        .font(.caption)
                        .foregroundColor(textSecondary)

                        VStack(spacing: 6) {
                            HStack {
                                Text("Volume")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(viewModel.speakerVolume))%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(textSecondary)
                            }

                            Slider(value: $viewModel.speakerVolume, in: 0...100, step: 1)
                                .tint(accent)
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
                                    .foregroundColor(textSecondary)
                            }

                            Slider(value: $viewModel.testToneFrequency, in: 300...2400, step: 10)
                                .tint(accent)
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
                                .background(controlFill)
                                .cornerRadius(10)
                        }
                        .foregroundColor(textPrimary)
                    }

                    // --- Device ---
                    sectionCard {
                        Label("Device", systemImage: "cpu")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(textSecondary)

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.hasSpeakerAmp
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(viewModel.hasSpeakerAmp ? successTint : dangerTint)
                            Text("MAX98357A Amp")
                                .font(.subheadline)
                            Spacer()
                            Text(viewModel.hasSpeakerAmp ? "Ready" : "Not Ready")
                                .font(.caption)
                                .foregroundColor(textSecondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.hasDRV2605L
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(viewModel.hasDRV2605L ? successTint : dangerTint)
                            Text("Haptic Driver")
                                .font(.subheadline)
                            Spacer()
                            Text(viewModel.hasDRV2605L ? "Connected" : "Not Found")
                                .font(.caption)
                                .foregroundColor(textSecondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.batteryLevelPercent == nil ? "battery.25" : "battery.75")
                                .foregroundColor(viewModel.batteryLevelPercent == nil ? cautionTint : successTint)
                            Text("Battery")
                                .font(.subheadline)
                            Spacer()
                            Text(viewModel.batteryStatusText)
                                .font(.caption)
                                .foregroundColor(textSecondary)
                        }
                    }

                    // --- Disconnect ---
                    Button {
                        viewModel.disconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.subheadline)
                            .foregroundColor(dangerTint)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("Awaken")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(textSecondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        withAnimation {
                            theme.toggle()
                        }
                    } label: {
                        Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                            .foregroundColor(theme.isDark ? warmHighlight : accentDeep)
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
                if isAlarmAlertVisible {
                    alarmQuickActionsBar
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
            .onChange(of: isAlarmAlertVisible) { _, isVisible in
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

    var alarmQuickActionsBar: some View {
        HStack(spacing: 10) {
            Button {
                voiceMessageViewModel.stopAlarmAudio()
                viewModel.snoozeAlarm()
            } label: {
                Label("Snooze", systemImage: "zzz")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(warmHighlight.opacity(0.35))
                    .cornerRadius(12)
            }
            .foregroundColor(accentDeep)

            Button {
                voiceMessageViewModel.stopAlarmAudio()
                viewModel.stopAlarm()
            } label: {
                Label("Shut Off", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(accentSoft.opacity(0.85))
                    .cornerRadius(12)
            }
            .foregroundColor(accentDeep)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(warmPaper.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(cardStroke.opacity(0.6))
                .frame(height: 1)
        }
    }

    // MARK: - Alarm Overlay

    var alarmOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [warmPaper, warmBase, accentSoft.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Circle()
                    .fill(accentSoft.opacity(0.75))
                    .frame(width: 128, height: 128)
                    .overlay(
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 48))
                            .foregroundColor(accentDeep)
                    )
                    .padding(.bottom, 20)

                Text("WAKE UP")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(accentDeep)
                    .padding(.bottom, 12)

                Text(Date(), style: .time)
                    .font(.system(size: 60, weight: .light, design: .rounded))
                    .foregroundColor(accentDeep.opacity(0.9))

                Spacer()

                // Snooze
                Button {
                    voiceMessageViewModel.stopAlarmAudio()
                    viewModel.snoozeAlarm()
                } label: {
                    VStack(spacing: 4) {
                        Text("SNOOZE")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("5 minutes")
                            .font(.subheadline)
                            .opacity(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(warmHighlight)
                    .foregroundColor(accentDeep)
                    .cornerRadius(20)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // Stop
                Button {
                    voiceMessageViewModel.stopAlarmAudio()
                    viewModel.stopAlarm()
                } label: {
                    Text("SHUT OFF")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(cardBackground)
                        .foregroundColor(accentDeep)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(cardStroke.opacity(0.9), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
    }

    // MARK: - Helpers

    func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .background(cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(cardStroke.opacity(0.95), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: accent.opacity(0.06), radius: 16, x: 0, y: 10)
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
                .background(repeatDays.contains(day) ? accent : controlFill)
                .foregroundColor(repeatDays.contains(day) ? .white : textSecondary)
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

    var weatherSummary: String {
        "\(weatherViewModel.forecastText). \(weatherViewModel.detailText)"
    }

    private func applyAlarmAudioOutput() {
        viewModel.setAlarmSoundEnabled(alarmAudioOutput == .deviceSpeaker)
        if alarmAudioOutput == .deviceSpeaker {
            voiceMessageViewModel.stopAlarmAudio()
        }
    }

    private func handleSetAlarm() {
        applyAlarmAudioOutput()
        if alarmAudioOutput == .deviceSpeaker,
           let pcmData = voiceMessageViewModel.devicePCMData, !pcmData.isEmpty {
            let time = alarmTime
            let effect = selectedWakeEffect
            let rate = voiceMessageViewModel.devicePCMSampleRate
            viewModel.syncDeviceAlarmAudio(pcmData, sampleRate: rate) { _ in
                viewModel.setAlarm(time: time)
                viewModel.setWakeEffect(effect)
            }
        } else {
            viewModel.setAlarm(time: alarmTime)
            viewModel.setWakeEffect(selectedWakeEffect)
        }
    }

    private func handleSyncToDevice() {
        guard let pcmData = voiceMessageViewModel.devicePCMData, !pcmData.isEmpty else { return }
        let rate = voiceMessageViewModel.devicePCMSampleRate
        viewModel.syncDeviceAlarmAudio(pcmData, sampleRate: rate) { _ in }
    }

    private var cardBackground: some ShapeStyle {
        warmPaper
    }

    private var spaBackground: some View {
        ZStack {
            LinearGradient(
                colors: [warmPaper, warmBase, warmBaseDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(accentSoft.opacity(0.7))
                .frame(width: 280, height: 280)
                .blur(radius: 28)
                .offset(x: 140, y: -210)

            Circle()
                .fill(warmHighlight.opacity(0.28))
                .frame(width: 240, height: 240)
                .blur(radius: 36)
                .offset(x: -150, y: 260)

            Circle()
                .fill(warmPaper.opacity(0.9))
                .frame(width: 210, height: 210)
                .blur(radius: 18)
                .offset(x: -120, y: -300)
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
