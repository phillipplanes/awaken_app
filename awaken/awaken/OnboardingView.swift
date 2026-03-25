import SwiftUI

struct OnboardingView: View {
    @Binding var isComplete: Bool
    @EnvironmentObject private var theme: AppTheme
    @State private var page = 0
    @State private var firstName: String = UserProfile.load().firstName
    @State private var motivations: Set<String> = UserProfile.load().motivations
    @State private var stressors: Set<String> = UserProfile.load().stressors
    @FocusState private var focusedField: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [theme.warmBase, theme.warmPaper],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(i <= page ? theme.accent : theme.controlFill)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 60)
                .padding(.bottom, 30)

                TabView(selection: $page) {
                    welcomePage.tag(0)
                    motivationsPage.tag(1)
                    stressorsPage.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: page)
            }
        }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Hi.")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundColor(theme.textPrimary)

            Text("Time to")
                .font(.system(size: 32, weight: .semibold, design: .default))
                .foregroundColor(theme.textSecondary)

            Text("AWAKEN")
                .font(.system(size: 48, weight: .black, design: .default))
                .tracking(4)
                .foregroundColor(theme.accent)

            Text("What's your\nfirst name?")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)

            TextField("Your first name", text: $firstName)
                .focused($focusedField)
                .font(.system(size: 32, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
                .background(theme.controlFill)
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(theme.accent.opacity(0.4), lineWidth: 2)
                )
                .foregroundColor(theme.textPrimary)
                .padding(.horizontal, 40)

            Spacer()

            nextButton(disabled: firstName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Motivations

    private var motivationsPage: some View {
        VStack(spacing: 20) {
            Text("What motivates you?")
                .font(.title2.weight(.bold))
                .foregroundColor(theme.textPrimary)
                .padding(.top, 20)

            Text("Select all that apply. This helps craft your wake-up messages.")
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(UserProfile.motivationOptions, id: \.self) { option in
                        checkRow(option, isSelected: motivations.contains(option)) {
                            toggleMotivation(option)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            nextButton(disabled: motivations.isEmpty)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Stressors

    private var stressorsPage: some View {
        VStack(spacing: 20) {
            Text("What stresses you out?")
                .font(.title2.weight(.bold))
                .foregroundColor(theme.textPrimary)
                .padding(.top, 20)

            Text("Your alarm messages will gently help you face these.")
                .font(.subheadline)
                .foregroundColor(theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(UserProfile.stressorOptions, id: \.self) { option in
                        checkRow(option, isSelected: stressors.contains(option)) {
                            toggleStressor(option)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Button {
                finishOnboarding()
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(stressors.isEmpty ? theme.accent.opacity(0.4) : theme.accent)
                    .cornerRadius(14)
            }
            .disabled(stressors.isEmpty)
            .padding(.horizontal, 32)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Components

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
            .background(isSelected ? theme.accent.opacity(0.08) : theme.warmPaper)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
    }

    private func nextButton(disabled: Bool) -> some View {
        Button {
            withAnimation {
                focusedField = false
                page += 1
            }
        } label: {
            Text("Continue")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(disabled ? theme.accent.opacity(0.4) : theme.accent)
                .cornerRadius(14)
        }
        .disabled(disabled)
        .padding(.horizontal, 32)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func toggleMotivation(_ option: String) {
        if motivations.contains(option) {
            motivations.remove(option)
        } else {
            motivations.insert(option)
        }
    }

    private func toggleStressor(_ option: String) {
        if stressors.contains(option) {
            stressors.remove(option)
        } else {
            stressors.insert(option)
        }
    }

    private func finishOnboarding() {
        var profile = UserProfile()
        profile.firstName = firstName
        profile.motivations = motivations
        profile.stressors = stressors
        profile.onboardingComplete = true
        profile.save()
        isComplete = true
    }
}
