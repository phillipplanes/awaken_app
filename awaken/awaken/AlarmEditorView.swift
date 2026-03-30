import SwiftUI

struct AlarmEditorView: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @ObservedObject var weatherViewModel: AlarmWeatherViewModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss

    @State var alarmTime: Date
    @State var repeatDays: Set<Int>
    @State var selectedWakeEffect: UInt8
    @State var alarmType: AlarmType
    @State var voiceOption: VoiceOption
    @State var alarmAudioOutput: AlarmAudioOutput

    let editingID: UUID?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    editorTimeCard
                    editorPatternCard
                    editorVoiceCard
                    editorAudioCard
                    editorSaveButton
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .background(SpaBackground().ignoresSafeArea())
            .navigationTitle(editingID != nil ? "Edit Alarm" : "New Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(theme.textSecondary)
                }
            }
            .onChange(of: alarmTime) { _, newValue in
                weatherViewModel.scheduleRefresh(for: newValue)
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    // MARK: - Time & Days

    private var editorTimeCard: some View {
        SectionCard {
            Label("Alarm Time", systemImage: "alarm")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            DatePicker("", selection: $alarmTime, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .frame(height: 180)

            editorRepeatDays

            if !repeatDays.isEmpty {
                Text(repeatDaysSummary)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            editorWeatherRow
        }
    }

    private var editorRepeatDays: some View {
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

    private var editorWeatherRow: some View {
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
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Wake Pattern

    private var editorPatternCard: some View {
        SectionCard {
            Label("Wake-Up Pattern", systemImage: "waveform.path")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(wakeEffects) { effect in
                    Button {
                        selectedWakeEffect = effect.id
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

    // MARK: - Voice

    private var editorVoiceCard: some View {
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

            editorVoiceStatus
            editorVoiceButtons
        }
    }

    private var editorVoiceStatus: some View {
        Group {
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
        }
    }

    private var editorVoiceButtons: some View {
        HStack(spacing: 10) {
            Button {
                let weather = "\(weatherViewModel.forecastText). \(weatherViewModel.detailText)"
                Task {
                    await voiceMessageViewModel.generate(
                        alarmType: alarmType,
                        alarmTime: alarmTime,
                        weatherSummary: weather,
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
    }

    // MARK: - Audio Output

    private var editorAudioCard: some View {
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
        }
    }

    // MARK: - Save

    private var editorSaveButton: some View {
        Button { saveAlarm() } label: {
            HStack(spacing: 8) {
                Image(systemName: editingID != nil ? "pencil" : "alarm.fill")
                Text(editingID != nil ? "Update Alarm" : "Set Alarm")
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

    private func saveAlarm() {
        print("[ALARM-EDITOR] saveAlarm called, audioOutput=\(alarmAudioOutput.rawValue), editingID=\(String(describing: editingID))")
        viewModel.setAlarmSoundEnabled(alarmAudioOutput == .deviceSpeaker)

        if alarmAudioOutput == .deviceSpeaker,
           let pcmData = voiceMessageViewModel.devicePCMData, !pcmData.isEmpty {
            print("[ALARM-EDITOR] taking deviceSpeaker+PCM path")
            let time = alarmTime
            let days = repeatDays
            let effect = selectedWakeEffect
            let type = alarmType
            let voice = voiceOption
            let output = alarmAudioOutput
            let editID = editingID
            let rate = voiceMessageViewModel.devicePCMSampleRate
            viewModel.syncDeviceAlarmAudio(pcmData, sampleRate: rate) { _ in
                viewModel.setAlarm(time: time, repeatDays: days, wakeEffect: effect,
                                   alarmType: type, voiceOption: voice, audioOutput: output,
                                   editingID: editID)
                viewModel.setWakeEffect(effect)
            }
        } else {
            print("[ALARM-EDITOR] taking default (phone) path")
            viewModel.setAlarm(time: alarmTime, repeatDays: repeatDays, wakeEffect: selectedWakeEffect,
                               alarmType: alarmType, voiceOption: voiceOption, audioOutput: alarmAudioOutput,
                               editingID: editingID)
            viewModel.setWakeEffect(selectedWakeEffect)
        }
        dismiss()
    }
}
