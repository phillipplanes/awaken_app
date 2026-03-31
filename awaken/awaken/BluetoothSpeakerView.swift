import SwiftUI
import MediaPlayer

struct BluetoothSpeakerView: View {
    @StateObject private var audio = AudioRouteManager()
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    routeCard
                    controlsCard
                    keepAliveCard
                }
                .padding(.horizontal)
            }
            .background(SpaBackground().ignoresSafeArea())
            .navigationTitle("Speaker Test")
        }
    }

    // MARK: - Audio Route

    private var routeCard: some View {
        SectionCard {
            Label("Audio Route", systemImage: "hifispeaker.2")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            HStack(spacing: 10) {
                Image(systemName: audio.isA2DPActive ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(audio.isA2DPActive ? theme.successTint : theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.currentRouteName)
                        .font(.subheadline.weight(.medium))
                    Text(audio.isA2DPActive ? "A2DP connected" : "Tap below to select AWAKEN-audio")
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }
                Spacer()
            }

            RoutePickerButton()
                .frame(height: 44)
                .frame(maxWidth: .infinity)

            if !audio.isA2DPActive {
                Button {
                    if let url = URL(string: "App-Prefs:root=Bluetooth") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Open Bluetooth Settings", systemImage: "gear")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(theme.controlFill)
                        .cornerRadius(8)
                }
                .foregroundColor(theme.accent)

                Text("Pair AWAKEN-audio in Settings first, then select it above")
                    .font(.caption2)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Controls

    private var controlsCard: some View {
        SectionCard {
            Label("Test Tone", systemImage: "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.textSecondary)

            Button { audio.toggleTestTone() } label: {
                Label(
                    audio.isTestTonePlaying ? "Stop Tone" : "Play 440Hz Tone",
                    systemImage: audio.isTestTonePlaying ? "stop.fill" : "play.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(audio.isTestTonePlaying ? theme.dangerTint.opacity(0.15) : theme.controlFill)
                .cornerRadius(10)
            }
            .foregroundColor(audio.isTestTonePlaying ? theme.dangerTint : theme.textPrimary)

            VStack(spacing: 6) {
                HStack {
                    Text("Volume").font(.subheadline)
                    Spacer()
                    Text("\(Int(audio.volume * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(theme.textSecondary)
                }
                Slider(value: $audio.volume, in: 0...1)
                    .tint(theme.accent)
            }
        }
    }

    // MARK: - Keep Alive

    private var keepAliveCard: some View {
        SectionCard {
            Toggle(isOn: $audio.isKeepAliveOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Keep A2DP Alive", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(theme.textSecondary)
                    Text("Sends silent audio to prevent iOS from dropping the Bluetooth connection")
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }
            }
            .tint(theme.accent)
        }
    }
}

// MARK: - Route Picker (MPVolumeView shows A2DP Bluetooth devices)

struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        view.setRouteButtonImage(
            UIImage(systemName: "airplayaudio")?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal),
            for: .normal
        )
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
