import SwiftUI

struct AlarmOverlayView: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @ObservedObject var voiceMessageViewModel: VoiceMessageViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.warmPaper, theme.warmBase, theme.accentSoft.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Circle()
                    .fill(theme.accentSoft.opacity(0.75))
                    .frame(width: 128, height: 128)
                    .overlay(
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 48))
                            .foregroundColor(theme.accentDeep)
                    )
                    .padding(.bottom, 20)

                Text("WAKE UP")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(theme.accentDeep)
                    .padding(.bottom, 12)

                Text(Date(), style: .time)
                    .font(.system(size: 60, weight: .light, design: .rounded))
                    .foregroundColor(theme.accentDeep.opacity(0.9))

                Spacer()

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
                    .background(theme.warmHighlight)
                    .foregroundColor(theme.accentDeep)
                    .cornerRadius(20)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                Button {
                    voiceMessageViewModel.stopAlarmAudio()
                    viewModel.stopAlarm()
                } label: {
                    Text("SHUT OFF")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(theme.warmPaper)
                        .foregroundColor(theme.accentDeep)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(theme.cardStroke.opacity(0.9), lineWidth: 1)
                        )
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
    }
}
