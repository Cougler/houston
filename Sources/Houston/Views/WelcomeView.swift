import SwiftUI

/// First-launch welcome: three feature cards, each with a small looping
/// animation acting out what it describes — folders arriving in the sidebar,
/// a click becoming a terminal, git changes syncing up. Dismissed once,
/// never shown again (`welcomeSeen`).
struct WelcomeView: View {
    let onDismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                // The empty state's solar system, scaled down to a crest.
                SolarSystem()
                    .frame(width: 430, height: 430)
                    .scaleEffect(0.26)
                    .frame(width: 140, height: 116)
                Text("Welcome to Houston")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Mission control for your projects and coding agents.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)

            HStack(alignment: .top, spacing: 28) {
                WelcomeCard(
                    title: "Add your projects",
                    copy: "Add a single project or a whole folder of them. "
                        + "Everything gets a home in the sidebar.",
                    delay: 0.15
                ) { MiniSidebarAnimation() }
                WelcomeCard(
                    title: "Terminals, on the spot",
                    copy: "Click a project to cd into that directory, or "
                        + "open a fresh terminal from the sidebar.",
                    delay: 0.3
                ) { MiniTerminalAnimation() }
                WelcomeCard(
                    title: "Visualize git",
                    copy: "Work like in any terminal, while Houston tracks "
                        + "your git changes and remote sync live.",
                    delay: 0.45
                ) { MiniGitAnimation() }
            }

            Button(action: onDismiss) {
                Text("Start Exploring")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Theme.buttonFill, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.buttonStroke, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(appeared ? 1 : 0)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 56)
        // The card hugs its content and floats centered — the app shows all
        // around it.
        .background(
            // Same push-away-from-the-chrome surface as the git panel:
            // darker than the UI in dark mode, a clean card in light.
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.gitPanelFill)
                .shadow(color: .black.opacity(0.3), radius: 26, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }
}

/// One feature: animation stage above, words below.
private struct WelcomeCard<Animation: View>: View {
    let title: String
    let copy: String
    let delay: Double
    @ViewBuilder let animation: () -> Animation
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 12) {
            animation()
                .frame(width: 168, height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.panelFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                )
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(copy)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 190)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(delay)) { appeared = true }
        }
    }
}

/// Sidebar rows cascading in under a header — "your projects arrive".
private struct MiniSidebarAnimation: View {
    @State private var visible = 0
    private let rows = [
        (icon: "folder", name: "Apps"),
        (icon: "shippingbox", name: "hierarch"),
        (icon: "shippingbox", name: "portfolio"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("PROJECTS")
                .font(.system(size: 7, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 5) {
                    Image(systemName: rows[index].icon)
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textSecondary)
                    Text(rows[index].name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Theme.rowHovered)
                )
                .opacity(visible > index ? 1 : 0)
                .offset(x: visible > index ? 0 : -10)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                for count in 1...rows.count {
                    try? await Task.sleep(for: .seconds(0.45))
                    withAnimation(.easeOut(duration: 0.35)) { visible = count }
                }
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(.easeIn(duration: 0.3)) { visible = 0 }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
    }
}

/// A prompt typing itself out with a blinking block cursor — "a real shell".
private struct MiniTerminalAnimation: View {
    @State private var typed = 0
    @State private var cursorOn = true
    private let command = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(Theme.closeRed).frame(width: 5, height: 5)
                Circle().fill(Color(hex: 0xD9A621)).frame(width: 5, height: 5)
                Circle().fill(Theme.dotActive).frame(width: 5, height: 5)
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                Text("$ ")
                    .foregroundStyle(Theme.textSecondary)
                Text(String(command.prefix(typed)))
                    .foregroundStyle(Theme.text)
                Rectangle()
                    .fill(Theme.text.opacity(cursorOn ? 0.8 : 0))
                    .frame(width: 5, height: 11)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                cursorOn.toggle()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.8))
                for count in 1...command.count {
                    try? await Task.sleep(for: .seconds(0.14))
                    typed = count
                }
                try? await Task.sleep(for: .seconds(2.0))
                typed = 0
            }
        }
    }
}

/// Branch row where changes appear, then sync away — "git, watched live".
private struct MiniGitAnimation: View {
    /// 0 clean · 1 changes appear · 2 synced check.
    @State private var stage = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.heading)
                Text("main")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Circle()
                    .fill(Color(hex: 0xD97706))
                    .frame(width: 4, height: 4)
                    .opacity(stage == 1 ? 1 : 0)
            }
            HStack(spacing: 4) {
                Text("+24")
                    .foregroundStyle(Color(hex: 0x16A34A))
                Text("−7")
                    .foregroundStyle(Theme.closeRed)
            }
            .font(.system(size: 10, weight: .medium))
            .opacity(stage == 1 ? 1 : 0)
            .offset(y: stage == 1 ? 0 : 4)
            HStack(spacing: 4) {
                Image(systemName: stage == 2
                    ? "checkmark.circle.fill" : "arrow.up.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(stage == 2 ? Theme.dotActive : Theme.textSecondary)
                Text(stage == 2 ? "Synced" : "Push")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(stage == 2 ? Theme.dotActive : Theme.textSecondary)
            }
            .opacity(stage >= 1 ? 1 : 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.8))
                withAnimation(.easeOut(duration: 0.35)) { stage = 1 }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeOut(duration: 0.35)) { stage = 2 }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.easeIn(duration: 0.3)) { stage = 0 }
            }
        }
    }
}
