import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: AppTheme
    @State private var firstName: String = UserProfile.load().firstName
    @State private var motivations: Set<String> = UserProfile.load().motivations
    @State private var stressors: Set<String> = UserProfile.load().stressors
    @State private var showResetConfirmation = false
    var onReset: (() -> Void)?

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [theme.warmBase, theme.warmPaper],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {

                        // Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your Name")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.textSecondary)

                            TextField("First name", text: $firstName)
                                .font(.title3)
                                .padding(14)
                                .background(theme.controlFill)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.cardStroke, lineWidth: 1)
                                )
                                .foregroundColor(theme.textPrimary)
                        }

                        // Motivations
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What Motivates You")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.textSecondary)

                            ForEach(UserProfile.motivationOptions, id: \.self) { option in
                                checkRow(option, isSelected: motivations.contains(option)) {
                                    if motivations.contains(option) {
                                        motivations.remove(option)
                                    } else {
                                        motivations.insert(option)
                                    }
                                }
                            }
                        }

                        // Stressors
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What Stresses You Out")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.textSecondary)

                            ForEach(UserProfile.stressorOptions, id: \.self) { option in
                                checkRow(option, isSelected: stressors.contains(option)) {
                                    if stressors.contains(option) {
                                        stressors.remove(option)
                                    } else {
                                        stressors.insert(option)
                                    }
                                }
                            }
                        }

                        // Theme
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Appearance")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.textSecondary)

                            Picker("Theme", selection: Binding(
                                get: { theme.mode },
                                set: { _ in theme.toggle() }
                            )) {
                                Text("Dark").tag(AppTheme.Mode.dark)
                                Text("Light").tag(AppTheme.Mode.light)
                            }
                            .pickerStyle(.segmented)
                        }

                        // Reset
                        Button {
                            showResetConfirmation = true
                        } label: {
                            Text("Reset & Redo Setup")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(theme.dangerTint)
                                .cornerRadius(12)
                        }
                        .padding(.top, 12)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        saveProfile()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(theme.accent)
                }
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .alert("Reset Personal Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                var fresh = UserProfile()
                fresh.onboardingComplete = false
                fresh.save()
                dismiss()
                onReset?()
            }
        } message: {
            Text("This will clear your name, motivations, and stressors, and return to the setup screens.")
        }
    }

    private func saveProfile() {
        var profile = UserProfile.load()
        profile.firstName = firstName
        profile.motivations = motivations
        profile.stressors = stressors
        profile.save()
    }

    private func checkRow(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body)
                    .foregroundColor(theme.textPrimary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? theme.accent : theme.textSecondary.opacity(0.4))
                    .font(.title3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(isSelected ? theme.accent.opacity(0.08) : theme.controlFill)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
    }
}
