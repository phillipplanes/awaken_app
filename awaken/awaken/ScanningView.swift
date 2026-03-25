import SwiftUI
import CoreBluetooth

struct ScanningView: View {
    @ObservedObject var viewModel: BluetoothViewModel
    @EnvironmentObject private var theme: AppTheme

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(theme.accentSoft.opacity(0.65))
                            .frame(width: 104, height: 104)

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 40))
                            .foregroundColor(theme.accentDeep)
                    }

                    Text("Searching for AWAKEN")
                        .font(.title2.weight(.semibold))

                    Text(viewModel.connectionStatus)
                        .font(.subheadline)
                        .foregroundColor(theme.accentDeep.opacity(0.7))

                    if viewModel.connectionStatus.contains("Scanning") {
                        ProgressView()
                            .padding(.top, 4)
                            .tint(theme.accent)

                        Text("Please ensure that AWAKEN is powered on and nearby.")
                            .font(.caption)
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .background(theme.warmPaper)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(theme.cardStroke.opacity(0.9), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: theme.accent.opacity(0.08), radius: 24, x: 0, y: 14)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)

                if !viewModel.discoveredPeripherals.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("DEVICES")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.accentDeep.opacity(0.7))
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)

                        ForEach(viewModel.discoveredPeripherals, id: \.identifier) { peripheral in
                            Button {
                                viewModel.connect(to: peripheral)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "bed.double.fill")
                                        .font(.title3)
                                        .foregroundColor(theme.accent)
                                        .frame(width: 36)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(peripheral.name ?? "Unknown Device")
                                            .font(.body.weight(.medium))
                                            .foregroundColor(theme.textPrimary)
                                        Text("AWAKEN Alarm Clock")
                                            .font(.caption)
                                            .foregroundColor(theme.textSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(theme.accentDeep.opacity(0.55))
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                            }
                        }
                    }
                    .background(theme.warmPaper)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(theme.cardStroke.opacity(0.9), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: theme.accent.opacity(0.06), radius: 18, x: 0, y: 10)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("AWAKEN")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation { theme.toggle() }
                    } label: {
                        Image(systemName: theme.isDark ? "sun.max.fill" : "moon.fill")
                            .foregroundColor(theme.isDark ? theme.warmHighlight : theme.accentDeep)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { viewModel.startScanning() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .tint(theme.accentDeep)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }
}
