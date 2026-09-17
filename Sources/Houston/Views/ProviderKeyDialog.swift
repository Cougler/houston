import SwiftUI

/// The provider API-key dialog: shown centered over a scrim (like the
/// capsule dialog) when the user picks "Use an API Key…" / "Sign in to …"
/// for a cloud provider. The browser is already open at the provider's
/// key console; this is where the minted key lands. Replaces an NSAlert.
struct ProviderKeyDialog: View {
    let provider: ChatProvider
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var key = ""
    @FocusState private var fieldFocused: Bool

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.buttonActiveStroke)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.buttonActiveFill))
            Text("Sign in to \(provider.name)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Your browser is open at \(provider.name)'s console. "
                + "Sign in there, create an API key, and paste it below. "
                + "The key stays on this Mac and is handed to the agent "
                + "only when a \(provider.name) chat runs.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API key", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit(save)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusControl + 2)
                        .fill(Theme.buttonFill.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusControl + 2)
                        .strokeBorder(
                            fieldFocused
                                ? Theme.buttonActiveStroke.opacity(0.7)
                                : Theme.buttonStroke,
                            lineWidth: 1
                        )
                )
                .padding(.top, 2)

            HStack(spacing: 10) {
                LinkButton(title: "Reopen the key console") {
                    ProviderAuthStore.shared.openConsole(provider)
                }
                Spacer(minLength: 4)
                DialogButton(title: "Cancel", action: onCancel)
                DialogButton(title: "Save Key", primary: true, action: save)
                    .disabled(trimmedKey.isEmpty)
                    .opacity(trimmedKey.isEmpty ? 0.4 : 1)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .fill(Theme.gitPanelFill)
                .shadow(
                    color: Theme.floatShadowColor,
                    radius: Theme.floatShadowRadius,
                    x: 0, y: Theme.floatShadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusFloat)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
        .onExitCommand(perform: onCancel)
        // One hop past the mount, like every focus claim in Houston — a
        // same-pass claim lands before the field is in the window.
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private func save() {
        let value = trimmedKey
        guard !value.isEmpty else { return }
        onSave(value)
    }
}
