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
]

// MARK: - Main View

struct ContentView: View {
    @StateObject private var viewModel = BluetoothViewModel()
    @StateObject private var weatherViewModel = AlarmWeatherViewModel()
    @StateObject private var voiceMessageViewModel = VoiceMessageViewModel()
    @State private var alarmTime = Date()
    @State private var alarmType: AlarmType = .focus
    @State private var voiceOption: VoiceOption = .shimmer
    @State private var selectedWakeEffect: UInt8 = 1
    @State private var intensityDebounce: DispatchWorkItem?
    @State private var speakerDebounce: DispatchWorkItem?
    @State private var showTestSection = false

    private let accent = Color.indigo

    var isConnected: Bool {
        let status = viewModel.connectionStatus
        return status == "Connected" || status == "Discovering services..." || status.hasPrefix("Reconnecting...") || status == "Connecting..."
    }

    var shouldShowAudioRouteWarning: Bool {
        isConnected && !viewModel.isAwakenAudioRouteActive
    }

    var body: some View {
        ZStack {
            if isConnected {
                connectedView
            } else {
                scanningView
            }

            if viewModel.alarmFiring {
                alarmOverlay
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.alarmFiring)
    }

    // MARK: - Scanning View

    var scanningView: some View {
        NavigationView {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundColor(accent.opacity(0.5))

                    Text("Searching for Awaken")
                        .font(.title3.weight(.medium))

                    Text(viewModel.connectionStatus)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if viewModel.connectionStatus.contains("Scanning") {
                        ProgressView()
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 40)

                if !viewModel.discoveredPeripherals.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DEVICES")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
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
                                            .foregroundColor(.primary)
                                        Text("Awaken Alarm Clock")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Awaken")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { viewModel.startScanning() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
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
                                .foregroundColor(viewModel.hasVerifiedLiveAlarm ? .green : .orange)
                            Text(viewModel.liveAlarmVerificationMessage)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background((viewModel.hasVerifiedLiveAlarm ? Color.green : Color.orange).opacity(0.12))
                        .cornerRadius(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if shouldShowAudioRouteWarning {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bluetooth audio route is not set to Awaken-Stream-Hybrid")
                                    .font(.subheadline.weight(.semibold))
                                Text("Use Audio Output below to pair/select Awaken-Stream-Hybrid-XXXX in iOS Bluetooth settings.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.14))
                        .cornerRadius(12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    sectionCard {
                        Label("Connection Status", systemImage: "dot.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isConnected ? .green : .red)
                            Text("BLE (Awaken-Control)")
                                .font(.subheadline)
                            Spacer()
                            Text(isConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isAwakenAudioRouteActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(viewModel.isAwakenAudioRouteActive ? .green : .orange)
                            Text("A2DP Route (Awaken-Stream-Hybrid)")
                                .font(.subheadline)
                            Spacer()
                            Text(viewModel.isAwakenAudioRouteActive ? "Active" : "Not Selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // --- Alarm Time ---
                    sectionCard {
                        Label("Alarm Time", systemImage: "alarm")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        DatePicker("", selection: $alarmTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.wheel)
                            .dynamicTypeSize(.accessibility5)
                            .scaleEffect(x: 1.6, y: 1.6)
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)

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
                                    .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                        }
                    }

                    // --- Wake-Up Pattern ---
                    sectionCard {
                        Label("Wake-Up Pattern", systemImage: "waveform.path")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        Text("Tapping previews the vibration")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(wakeEffects) { effect in
                                Button {
                                    selectedWakeEffect = effect.id
                                    viewModel.playEffect(effect.id)
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
                                            : Color(.tertiarySystemGroupedBackground)
                                    )
                                    .foregroundColor(
                                        selectedWakeEffect == effect.id ? accent : .primary
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
                            .foregroundColor(.secondary)

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
                            .foregroundColor(.secondary)

                        if !voiceMessageViewModel.scriptText.isEmpty {
                            Text(voiceMessageViewModel.scriptText)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(.tertiarySystemGroupedBackground))
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
                                Label("Generate", systemImage: "wand.and.stars")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .cornerRadius(10)
                            }
                            .foregroundColor(.primary)

                            Button {
                                voiceMessageViewModel.playPreview()
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .cornerRadius(10)
                            }
                            .foregroundColor(.primary)
                        }

                        HStack(spacing: 10) {
                            Button {
                                guard let pcm = voiceMessageViewModel.devicePCMData else { return }
                                viewModel.uploadVoiceAlarmPCM(pcm) { _ in }
                            } label: {
                                Label("Send to Speaker", systemImage: "dot.radiowaves.left.and.right")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .cornerRadius(10)
                            }
                            .foregroundColor(.primary)
                            .disabled(voiceMessageViewModel.devicePCMData == nil)

                            Button {
                                viewModel.playUploadedVoiceAlarm()
                            } label: {
                                Label("Play on Speaker", systemImage: "speaker.wave.2.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.tertiarySystemGroupedBackground))
                                    .cornerRadius(10)
                            }
                            .foregroundColor(.primary)
                        }

                        if !viewModel.voiceUploadStatus.isEmpty {
                            Text(viewModel.voiceUploadStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if viewModel.voiceUploadProgress > 0 && viewModel.voiceUploadProgress < 1 {
                            ProgressView(value: viewModel.voiceUploadProgress)
                        }
                    }

                    // --- Set Alarm ---
                    Button {
                        viewModel.setAlarm(time: alarmTime)
                        viewModel.setWakeEffect(selectedWakeEffect)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "alarm.fill")
                            Text("Set Alarm")
                                .fontWeight(.semibold)
                        }
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(accent)
                        .foregroundColor(.white)
                        .cornerRadius(14)
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
                                            .foregroundColor(.secondary)
                                        Button("Stop") {
                                            viewModel.vibrationIntensity = 0
                                            viewModel.stopVibration()
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.red)
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
                                            .background(Color(.tertiarySystemGroupedBackground))
                                            .foregroundColor(.primary)
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 12)
                        } label: {
                            Label("Test Vibration", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                        .tint(.secondary)
                    }

                    // --- Device ---
                    sectionCard {
                        Label("Speaker", systemImage: "speaker.wave.2")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        Toggle("Alarm sound", isOn: $viewModel.alarmSoundEnabled)
                            .onChange(of: viewModel.alarmSoundEnabled) { _, enabled in
                                viewModel.setAlarmSoundEnabled(enabled)
                            }

                        VStack(spacing: 6) {
                            HStack {
                                Text("Volume")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(viewModel.speakerVolume))%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.secondary)
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
                        }

                        VStack(spacing: 6) {
                            HStack {
                                Text("Test Frequency")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(Int(viewModel.testToneFrequency)) Hz")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }

                            Slider(value: $viewModel.testToneFrequency, in: 300...2400, step: 10)
                                .tint(accent)
                        }

                        Button {
                            viewModel.playSpeakerTestTone()
                            voiceMessageViewModel.playTestTone(frequencyHz: viewModel.testToneFrequency)
                        } label: {
                            Label("Play Test Tone", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .cornerRadius(10)
                        }
                        .foregroundColor(.primary)
                    }

                    sectionCard {
                        Label("Audio Output", systemImage: "airplayaudio")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        Text("Pair or select the Classic Bluetooth audio target named Awaken-Stream-Hybrid-XXXX (same suffix as your Awaken-Control-XXXX).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.isAwakenAudioRouteActive ? "checkmark.circle.fill" : "wave.3.right")
                                .foregroundColor(viewModel.isAwakenAudioRouteActive ? .green : accent)
                            Text(viewModel.audioRouteStatus)
                                .font(.subheadline)
                            Spacer()
                        }

                        Text("Current route: \(viewModel.audioRouteName)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button {
                            viewModel.refreshAudioRoute()
                        } label: {
                            Label("Check Audio Route", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color(.tertiarySystemGroupedBackground))
                                .cornerRadius(10)
                        }
                        .foregroundColor(.primary)
                    }

                    // --- Device ---
                    sectionCard {
                        Label("Device", systemImage: "cpu")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.hasSpeakerAmp
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(viewModel.hasSpeakerAmp ? .green : .red)
                            Text("MAX98357A Amp")
                                .font(.subheadline)
                            Spacer()
                            Text(viewModel.hasSpeakerAmp ? "Ready" : "Not Ready")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: viewModel.hasDRV2605L
                                  ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(viewModel.hasDRV2605L ? .green : .red)
                            Text("Haptic Driver")
                                .font(.subheadline)
                            Spacer()
                            Text(viewModel.hasDRV2605L ? "Connected" : "Not Found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // --- Disconnect ---
                    Button {
                        viewModel.disconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Awaken")
            .safeAreaInset(edge: .bottom) {
                if viewModel.alarmFiring {
                    alarmQuickActionsBar
                }
            }
            .onAppear {
                weatherViewModel.scheduleRefresh(for: alarmTime)
                viewModel.refreshAudioRoute()
            }
            .onChange(of: alarmTime) { _, newValue in
                weatherViewModel.scheduleRefresh(for: newValue)
            }
            .onChange(of: viewModel.alarmFiring) { _, isFiring in
                if isFiring {
                    if voiceMessageViewModel.devicePCMData != nil {
                        voiceMessageViewModel.playAlarmAudioIfAvailable()
                    }
                    viewModel.playUploadedVoiceAlarm()
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
                    .background(Color.orange.opacity(0.18))
                    .cornerRadius(12)
            }
            .foregroundColor(.orange)

            Button {
                voiceMessageViewModel.stopAlarmAudio()
                viewModel.stopAlarm()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.16))
                    .cornerRadius(12)
            }
            .foregroundColor(.red)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Alarm Overlay

    var alarmOverlay: some View {
        ZStack {
            Color.black.opacity(0.95)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image(systemName: "alarm.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.orange)
                    .padding(.bottom, 20)

                Text("WAKE UP")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.bottom, 12)

                Text(Date(), style: .time)
                    .font(.system(size: 60, weight: .light, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))

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
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(20)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                // Stop
                Button {
                    voiceMessageViewModel.stopAlarmAudio()
                    viewModel.stopAlarm()
                } label: {
                    Text("STOP")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
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
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(16)
    }

    var weatherSummary: String {
        "\(weatherViewModel.forecastText). \(weatherViewModel.detailText)"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
