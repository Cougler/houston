import SwiftUI

/// First-launch onboarding: a full-window takeover on the empty-state sky.
/// The window opens with no chrome at all: just the solar system and a
/// welcome headline. Continuing flies past the solar system into four
/// paginated steps on one shadcn-style card (2026-09-27 restyle): Connect
/// Your AI, Projects, Threads, Sharing — each a large live demo that
/// plays on its own and answers clicks, the next click marked by a ring
/// around the control (never a dot over it). Shown until dismissed once
/// (`onboardingSeen`), replayable from the footer gear.
struct OnboardingView: View {
    let onDismiss: () -> Void

    /// -1 is the welcome screen; 0..<steps.count the paginated steps.
    @State private var page = -1
    @State private var appeared = false
    private let steps = OnboardingStep.allCases
    private var pastWelcome: Bool { page >= 0 }
    private var isLast: Bool { page == steps.count - 1 }

    var body: some View {
        ZStack {
            NightSky()

            // The solar system belongs to the welcome screen; leaving it
            // flies past the system entirely and the per-page decor takes over.
            SolarSystem()
                .scaleEffect(pastWelcome ? 1.6 : 1)
                .opacity(pastWelcome ? 0 : 1)
                // Lifted on the welcome screen so the system and the headline
                // below it read as one vertically balanced composition. The
                // empty state underneath starts with the same lift while the
                // sidebar is hidden, so the dismissal crossfade is static —
                // the glide down to center happens on the other side, in one
                // motion with the sidebar slide.
                .offset(y: pastWelcome ? 0 : -56)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .rise(appeared, delay: 0)

            // Deep-space set dressing for the steps, trailing the page swaps
            // on its own slightly laggier spring for the parallax feel.
            ParallaxSpace(page: max(0, page))
                .opacity(pastWelcome ? 1 : 0)
                .animation(.spring(duration: 0.65, bounce: 0.14), value: page)

            // Spotlight: a soft radial falloff dims the periphery and holds
            // the eye on the card.
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.3)],
                center: .center,
                startRadius: 170,
                endRadius: 780
            )
            .opacity(pastWelcome ? 1 : 0)
            .allowsHitTesting(false)

            if pastWelcome {
                stepCard
                    .transition(.opacity.combined(with: .offset(y: 18)))
            } else {
                welcome
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.emptyStateBackground)
        .clipped()
        .onExitCommand(perform: onDismiss)
        .onAppear {
            // Next runloop tick so the first frame renders hidden and the
            // entrance actually animates.
            DispatchQueue.main.async { appeared = true }
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Welcome to Houston")
                    .font(.system(size: 32, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.skyText)
                Text("Mission control for your coding agents.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.skyTextSecondary)
            }
            .rise(appeared, delay: 0.35)

            VStack(spacing: 14) {
                OnbButton("Get Started", primary: true, wide: true) { go(to: 0) }
                OnbQuiet("Skip setup", action: onDismiss)
            }
            .padding(.top, 32)
            .rise(appeared, delay: 0.55)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 80)
    }

    // MARK: Step card

    /// One card for every step (shadcn dialog grammar: card fill, hairline,
    /// soft shadow): the demo stage on top, title and copy under it, dots
    /// and controls in the footer. Fixed width and stage height so the
    /// card never resizes between steps.
    private var stepCard: some View {
        let step = steps[max(0, min(page, steps.count - 1))]
        return VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                OnboardingStage(step: step, onDismiss: onDismiss)
                    .frame(height: 380)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 16, topTrailingRadius: 16
                    ))
                VStack(spacing: 8) {
                    Text(step.title)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.text)
                    Text(step.copy)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 560)
                        .frame(height: 44, alignment: .top)
                }
                .padding(.top, 22)
                .padding(.horizontal, 32)
                Divider()
                    .overlay(Theme.borderSidebar)
                    .padding(.top, 20)
                footer
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
            .id(page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 32)),
                removal: .opacity.combined(with: .offset(x: -32))
            ))
            .frame(width: 800)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.menuFill)
                    .shadow(color: Color.black.opacity(0.35), radius: 40, x: 0, y: 20)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.borderSidebar, lineWidth: 1)
            )
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            dots
            Spacer()
            if !isLast {
                OnbQuiet("Skip", action: onDismiss)
            }
            if page > 0 {
                OnbButton("Back") { go(to: page - 1) }
            }
            OnbButton(isLast ? "Start Using Houston" : "Continue", primary: true) {
                isLast ? onDismiss() : go(to: page + 1)
            }
        }
    }

    /// Active step: a wide pill in the accent; the rest quiet.
    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.link : Theme.textSecondary.opacity(0.3))
                    .frame(width: index == page ? 18 : 6, height: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { go(to: index) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: page)
        .padding(.leading, 6)
    }

    /// Crossing the welcome boundary rides the slow spring that also
    /// recedes or restores the solar system; hops between steps stay quick.
    private func go(to index: Int) {
        let crossing = pastWelcome != (index >= 0)
        withAnimation(
            crossing ? .spring(duration: 0.8, bounce: 0.12)
                     : .easeOut(duration: 0.28)
        ) {
            page = index
        }
    }
}

// MARK: - shadcn-style buttons

/// The default button: rounded-md, medium weight. Primary is the accent
/// fill with white text; secondary is the control fill with a hairline.
private struct OnbButton: View {
    let title: String
    var primary = false
    var wide = false
    let action: () -> Void

    init(_ title: String, primary: Bool = false, wide: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.primary = primary
        self.wide = wide
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(primary ? .white : Theme.text)
                .padding(.horizontal, wide ? 28 : 16)
                .frame(height: wide ? 40 : 34)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(primary ? Theme.ctaFill : Theme.buttonFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(primary ? .clear : Theme.buttonStroke, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// The ghost button: text only, secondary ink, no chrome.
private struct OnbQuiet: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Steps

private enum OnboardingStep: CaseIterable {
    case connect, projects, threads, share

    var title: String {
        switch self {
        case .connect: "Connect Your AI"
        case .projects: "Projects"
        case .threads: "Threads"
        case .share: "Sharing"
        }
    }

    /// Matter-of-fact copy: what the thing is and what a click does.
    var copy: String {
        switch self {
        case .connect:
            "Sign in with the subscriptions you already have, or run models "
                + "on your Mac. Change any of this later from a chat's model menu."
        case .projects:
            "Pin a project or a folder of them. Right-click a project to pin "
                + "it above the divider. Clicking a project opens its most recent "
                + "chat, or the one waiting on you."
        case .threads:
            "Select any part of a reply and right-click to ask about just "
                + "that. The quote stays highlighted with its reply count, and "
                + "the thread opens beside the chat while the conversation stays put."
        case .share:
            "A running dev server is reachable from any device on your Wi-Fi "
                + "at project.local, with a QR code for phones. Public links are "
                + "part of Houston Live."
        }
    }
}

/// The demo area: a fixed-size stage on the panel fill, each vignette
/// drawn in Houston's own chrome at a readable size.
private struct OnboardingStage: View {
    let step: OnboardingStep
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch step {
            case .connect: ConnectAIStep(onLeaveForSignIn: onDismiss)
            case .projects: ProjectsVignette()
            case .threads: ThreadVignette()
            case .share: ShareVignette()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panelFill)
    }
}

// MARK: - Connect your AI

/// One row per provider — install state, sign-in state, and the one
/// action that moves it forward — plus MLX Core for local models.
/// Sign-ins that need a terminal (Claude, OpenAI, Grok run their own CLI
/// login) LEAVE onboarding first so the terminal is on screen; Gemini's
/// is browser OAuth and stays.
private struct ConnectAIStep: View {
    /// Dismiss onboarding so a terminal-driven sign-in is visible.
    let onLeaveForSignIn: () -> Void

    @ObservedObject private var providerAuth = ProviderAuthStore.shared
    @ObservedObject private var localModels = LocalModelStore.shared
    /// CLI presence, probed off-main once (each probe spawns a shell).
    @State private var installed: [String: Bool] = [:]
    @State private var claudeSignedIn = ConnectAIStep.claudeAccountPresent()

    var body: some View {
        VStack(spacing: 8) {
            ConnectProviderRow(
                name: "Claude", plan: "Claude Pro or Max, or an Anthropic API account",
                installed: installed["claude"], signedIn: claudeSignedIn,
                installURL: "https://claude.com/product/claude-code",
                installHint: "Install Claude Code"
            ) {
                onLeaveForSignIn()
                providerAuth.signInClaude()
            }
            ConnectProviderRow(
                name: "OpenAI", plan: "ChatGPT Plus or Pro, through Codex",
                installed: installed["codex"], signedIn: providerAuth.codexSignedIn,
                installURL: "https://github.com/openai/codex",
                installHint: "Install Codex"
            ) {
                onLeaveForSignIn()
                providerAuth.signInOpenAI()
            }
            ConnectProviderRow(
                name: "Google Gemini", plan: "Your Google account, through the Gemini CLI",
                installed: installed["gemini"],
                signedIn: providerAuth.signedIn(ChatProvider.gemini.id),
                installURL: "https://github.com/google-gemini/gemini-cli",
                installHint: "Install Gemini CLI"
            ) {
                providerAuth.signInGemini()
            }
            ConnectProviderRow(
                name: "Grok", plan: "Your xAI account, through Grok Build",
                installed: installed["grok"],
                signedIn: providerAuth.signedIn(ChatProvider.grok.id),
                installURL: "https://x.ai/cli",
                installHint: "Install Grok Build"
            ) {
                onLeaveForSignIn()
                PromptDelivery.login(.grok, project: NSHomeDirectory())
            }
            ConnectProviderRow(
                name: "MLX Core", plan: "Run open models locally on Apple silicon — no account",
                installed: mlxInstalled,
                signedIn: mlxInstalled == true,
                signedInLabel: "Installed",
                installURL: "https://github.com/ddalcu/mlx-serve/releases/latest",
                installHint: "Download MLX Core"
            ) {}
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let probed = await Task.detached(priority: .userInitiated) {
                var out: [String: Bool] = [:]
                for name in ["claude", "codex", "gemini", "grok"] {
                    out[name] = AgentTransport.resolveBinary(name) != nil
                }
                return out
            }.value
            installed = probed
        }
        // Coming back from a browser or terminal sign-in re-reads the
        // Claude marker; the provider store refreshes its own on activate.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            claudeSignedIn = Self.claudeAccountPresent()
        }
    }

    /// nil while MLX Core is still being detected.
    private var mlxInstalled: Bool? {
        switch localModels.mlxState {
        case .unknown: nil
        case .notInstalled: false
        case .installed: true
        }
    }

    /// Claude Code keeps the OAuth account summary in ~/.claude.json
    /// (`oauthAccount`, with the email) — present once `claude /login`
    /// finished; the token itself lives in the keychain.
    private static func claudeAccountPresent() -> Bool {
        let path = NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["oauthAccount"] is [String: Any]
    }
}

private struct ConnectProviderRow: View {
    let name: String
    let plan: String
    /// nil while the probe runs.
    let installed: Bool?
    let signedIn: Bool
    var signedInLabel = "Signed in"
    let installURL: String
    let installHint: String
    let signIn: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(plan)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            if signedIn {
                HStack(spacing: 5) {
                    LucideIcon("circle-check", size: 14)
                    Text(signedInLabel)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPositive)
            } else if installed == false {
                OnbButton(installHint) { Actions.openExternal(installURL) }
            } else {
                OnbButton("Sign in", action: signIn)
                    .disabled(installed == nil)
                    .opacity(installed == nil ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.menuFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
    }
}

// MARK: - Click-here ring

/// The "click this next" mark: a pulsing accent ring hugging the control
/// with a soft glow — the control stays fully readable underneath (the
/// old pulsing dot sat on top of it). Never intercepts the click.
private struct HintRing: View {
    var cornerRadius: CGFloat = 6
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius + 3)
            .strokeBorder(Theme.link, lineWidth: 1.5)
            .padding(-3)
            .shadow(color: Theme.link.opacity(0.7), radius: on ? 8 : 2)
            .opacity(on ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .allowsHitTesting(false)
            .onAppear { on = true }
    }
}

// MARK: - Mini chrome

/// The vignettes' shared pieces — the app's own grammar, near full size.
private enum Mini {
    static let page = Color(light: 0xF4F4F5, dark: 0x0B0B0D)
    static let bar = Color(light: 0xFFFFFF, dark: 0x18181B)
    static let bubble = Color(light: 0x7E4340, dark: 0x8F5350)
    /// Text selection wash (the system's, near enough) for the demo.
    static let selection = Color(light: 0xB4D5FE, dark: 0x3B5A8A)

    static func control(_ icon: String, hint: Bool = false) -> some View {
        LucideIcon(icon, size: 13)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.buttonFill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderSidebar, lineWidth: 1))
            .contentShape(Rectangle())
            .overlay { if hint { HintRing(cornerRadius: 6) } }
    }

    static func caps(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.heading)
    }

    /// A context menu as Houston draws it: card, hairline, rows.
    static func menu<Content: View>(@ViewBuilder _ rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 1) { rows() }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.menuFill)
                    .shadow(color: Color.black.opacity(0.25), radius: 14, x: 0, y: 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.borderSidebar, lineWidth: 1))
    }

    static func menuRow(_ title: String, hint: Bool = false, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hint ? Theme.rowHovered : .clear))
            .contentShape(Rectangle())
            .overlay { if hint { HintRing(cornerRadius: 5) } }
            .onTapGesture(perform: action)
    }

    static func menuDivider() -> some View {
        Rectangle().fill(Theme.borderSidebar).frame(height: 1).padding(.vertical, 3)
    }
}

// MARK: - Projects

/// The sidebar's Projects section, large: right-click a row → Pin → it
/// lifts above the divider. Plays on its own; clicks jump ahead.
private struct ProjectsVignette: View {
    /// 0 idle · 1 menu open on "showcase" · 2 showcase pinned.
    @State private var phase = 0

    private var pinned: [String] { phase == 2 ? ["hierarch", "showcase"] : ["hierarch"] }
    private var rest: [String] { phase == 2 ? ["portfolio", "spicy-resume"] : ["portfolio", "showcase", "spicy-resume"] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Mini.caps("PROJECTS").padding(.leading, 10).padding(.bottom, 6)
                ForEach(pinned, id: \.self) { name in row(name, pinned: true) }
                Rectangle().fill(Theme.borderSidebar).frame(height: 1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                ForEach(rest, id: \.self) { name in row(name, pinned: false) }
                HStack(spacing: 8) {
                    LucideIcon("plus", size: 13).foregroundStyle(Theme.textSecondary)
                    Text("Add a project").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 12).frame(height: 32)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .frame(width: 260)
            .frame(maxHeight: .infinity)
            .background(Mini.bar)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.borderSidebar).frame(width: 1) }

            // The page beside the sidebar: a chat opening on click.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("Hierarch").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                    LucideIcon("chevron-down", size: 12).foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Mini.bar))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderSidebar, lineWidth: 1))
                .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                Text("Retry logic for the webhook worker")
                    .font(.system(size: 12.5)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Mini.bubble))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("The worker retries with exponential backoff and gives up after five attempts, logging the payload.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text).lineSpacing(3)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Mini.page)
        .overlay(alignment: .topLeading) {
            if phase == 1 {
                Mini.menu {
                    Mini.menuRow("Open Terminal Here") {}
                    Mini.menuRow("Pin", hint: true) { advance() }
                    Mini.menuDivider()
                    Mini.menuRow("Reveal in Finder") {}
                    Mini.menuRow("Remove from Sidebar") {}
                }
                .frame(width: 190)
                .offset(x: 118, y: 158)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.2))
                advance()
            }
        }
    }

    private func row(_ name: String, pinned: Bool) -> some View {
        HStack(spacing: 8) {
            LucideIcon("package", size: 13).foregroundStyle(Theme.textSecondary)
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            if pinned { LucideIcon("pin", size: 11).foregroundStyle(Theme.textSecondary) }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(name == "hierarch" ? Theme.rowSelected
                    : (name == "showcase" && phase == 1) ? Theme.rowHovered : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .overlay { if name == "showcase", phase == 0 { HintRing(cornerRadius: 7).padding(.horizontal, 6) } }
        .onTapGesture { if name == "showcase", phase == 0 { advance() } }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            phase = (phase + 1) % 3
        }
    }
}

// MARK: - Threads

/// A reply at full size: select a run of text → right-click → "Ask About"
/// → the thread opens beside it with the quote split out, reply count
/// under the quoted words. Plays on its own; clicks jump ahead.
private struct ThreadVignette: View {
    /// 0 idle · 1 selection · 2 context menu · 3 thread open, question
    /// waiting · 4 sent and answered.
    @State private var phase = 0

    private let lead = "The booking card renders a skeleton while availability loads, matching the final layout so nothing shifts."
    private let before = "Availability is fetched "
    private let quote = "stale-while-revalidate: the cached range shows first"
    private let after = " and the refresh replaces it."
    private let tail = "A test renders the card with a pending promise and asserts the skeleton stays until it resolves."

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Mini.caps("CLAUDE")
                paragraph(Text(lead))
                middleParagraph
                paragraph(Text(tail))
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture { if phase == 0 { advance() } }

            if phase >= 3 {
                threadPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Mini.page)
        .overlay(alignment: .topLeading) {
            if phase == 2 {
                Mini.menu {
                    Mini.menuRow("Ask About \u{201C}stale-while-revalidate…\u{201D}", hint: true) { advance() }
                    Mini.menuRow("Copy") {}
                }
                .frame(width: 270)
                .offset(x: 150, y: 128)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(phase == 4 ? 3.2 : 2.0))
                advance()
            }
        }
    }

    private func paragraph(_ text: Text) -> some View {
        text.font(.system(size: 13)).foregroundStyle(Theme.text).lineSpacing(3)
            .opacity(phase >= 3 ? 0.55 : 1)
    }

    /// The paragraph the quote lives in: selection wash on the run while
    /// selecting, then (thread open) the run split out as a quote block
    /// with its reply chip beneath — exactly what the app renders.
    @ViewBuilder
    private var middleParagraph: some View {
        if phase >= 3 {
            VStack(alignment: .leading, spacing: 6) {
                Text(before.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 5) {
                    Text(quote)
                        .font(.system(size: 13)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.link.opacity(0.1)))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1).fill(Theme.link.opacity(0.7))
                                .frame(width: 2).padding(.vertical, 5).padding(.leading, 3)
                        }
                    HStack(spacing: 4) {
                        LucideIcon("message-square-text", size: 11)
                        Text(phase == 4 ? "1 reply" : "Thread").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.link)
                    .padding(.leading, 10)
                }
                Text(after.trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
            }
        } else {
            (Text(before)
                + Text(quote).foregroundColor(Theme.text)
                + Text(after))
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .overlay(alignment: .topLeading) {
                    // The selection wash over the quoted run — drawn as a
                    // band across the run's rough extent.
                    if phase >= 1 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Mini.selection.opacity(0.65))
                            .frame(width: 322, height: 18)
                            .offset(x: 138, y: 0)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if phase == 1 { advance() } }
                .overlay { if phase == 1 { HintRing(cornerRadius: 4).padding(-2) } }
        }
    }

    private var threadPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Mini.caps("THREAD")
                Spacer(minLength: 0)
                Mini.control("x", hint: phase == 4).onTapGesture { reset() }
            }
            Text(quote)
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.link).frame(width: 2) }
            if phase == 4 {
                Text("What happens if the refresh fails?")
                    .font(.system(size: 12.5)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Mini.bubble))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
                Text("The cached range stays on screen and the failure is logged; the next visit retries.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text).lineSpacing(3)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(phase == 4 ? "" : "What happens if the refresh fails?")
                    .font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(phase == 4 ? Theme.buttonFill : Mini.bubble)
                    .frame(width: 24, height: 24)
                    .overlay(LucideIcon("arrow-up", size: 12).foregroundStyle(phase == 4 ? Theme.textSecondary : .white))
                    .overlay { if phase == 3 { HintRing(cornerRadius: 12) } }
                    .onTapGesture { if phase == 3 { advance() } }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(Mini.page))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.borderSidebar, lineWidth: 1))
        }
        .padding(14)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Mini.bar)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.borderSidebar).frame(width: 1) }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            if phase == 4 { phase = 0 } else { phase += 1 }
        }
    }

    private func reset() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { phase = 0 }
    }
}

// MARK: - Sharing

/// A server's share card at full size: the row, the .local address, a QR
/// for phones, and the public-links slot.
private struct ShareVignette: View {
    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.dotActive).frame(width: 8, height: 8)
                    Text("hierarch").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                    Text("localhost:5173").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
                HStack(spacing: 8) {
                    LucideIcon("globe", size: 15).foregroundStyle(Theme.link)
                    Text("hierarch.local").font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(Theme.link)
                }
                .padding(.horizontal, 16).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.buttonFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.buttonStroke, lineWidth: 1))
                HStack(spacing: 8) {
                    LucideIcon("wifi", size: 13)
                    LucideIcon("smartphone", size: 14)
                    Text("Any device on your Wi-Fi").font(.system(size: 13))
                }
                .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 8) {
                    ComingSoonBadge()
                    Text("Public live URLs").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            qr
                .frame(width: 168, height: 168)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderSidebar, lineWidth: 1))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Mini.page)
    }

    /// A QR-looking module grid (fixed pattern, finder squares in the
    /// corners) — decoration, not a real code.
    private var qr: some View {
        let n = 21
        return Canvas { context, size in
            let cell = size.width / CGFloat(n)
            func finder(_ ox: Int, _ oy: Int) {
                for y in 0..<7 {
                    for x in 0..<7 {
                        let edge = x == 0 || y == 0 || x == 6 || y == 6
                        let core = (2...4).contains(x) && (2...4).contains(y)
                        if edge || core {
                            context.fill(
                                Path(CGRect(x: CGFloat(ox + x) * cell, y: CGFloat(oy + y) * cell,
                                            width: cell, height: cell)),
                                with: .color(.black)
                            )
                        }
                    }
                }
            }
            finder(0, 0); finder(n - 7, 0); finder(0, n - 7)
            var seed: UInt32 = 0x9E37_79B9
            for y in 0..<n {
                for x in 0..<n {
                    let inFinder = (x < 8 && y < 8) || (x >= n - 8 && y < 8) || (x < 8 && y >= n - 8)
                    if inFinder { continue }
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    if (seed >> 16) & 1 == 1 {
                        context.fill(
                            Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)),
                            with: .color(.black)
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Parallax set dressing

/// Decorative deep space behind the steps: small planets, soft glows,
/// and a ringed body scattered around the periphery, each pinned to a home
/// page. As the steps advance they slide opposite the page motion, nearer
/// features faster (`depth`), and fade in around their home page, so every
/// step gets its own slowly shifting sky.
private struct ParallaxSpace: View {
    let page: Int

    private enum Kind {
        case planet(Color, CGFloat)
        case ringed(Color, CGFloat)
        case glow(Color, CGFloat)
    }

    private struct Feature: Identifiable {
        let id: Int
        /// The position (fractions of the pane) it holds on its home page.
        let fx: CGFloat
        let fy: CGFloat
        /// 0 = far (barely moves) ... 1 = near (full parallax step).
        let depth: CGFloat
        /// The page this feature is fully faded in on.
        let home: Int
        let kind: Kind
    }

    /// Placed on the left/right bands so nothing drifts under the card;
    /// the fade-out over distance keeps travel from carrying a feature
    /// anywhere visible far from home.
    private static let features: [Feature] = [
        Feature(id: 0, fx: 0.10, fy: 0.22, depth: 0.25, home: 0, kind: .glow(Color(hex: 0xD97757), 150)),
        Feature(id: 1, fx: 0.90, fy: 0.17, depth: 0.70, home: 0, kind: .planet(Color(hex: 0x8FD3D9), 18)),
        Feature(id: 2, fx: 0.12, fy: 0.72, depth: 0.50, home: 1, kind: .planet(Color(hex: 0xE0C084), 11)),
        Feature(id: 3, fx: 0.91, fy: 0.68, depth: 0.85, home: 1, kind: .ringed(Color(hex: 0xD9C27E), 24)),
        Feature(id: 4, fx: 0.92, fy: 0.28, depth: 0.30, home: 2, kind: .glow(Color(hex: 0x5069D9), 130)),
        Feature(id: 5, fx: 0.09, fy: 0.40, depth: 0.60, home: 2, kind: .planet(Color(hex: 0x4A90D9), 14)),
        Feature(id: 6, fx: 0.88, fy: 0.84, depth: 0.45, home: 3, kind: .planet(Color(hex: 0xD9603B), 9)),
        Feature(id: 7, fx: 0.14, fy: 0.10, depth: 0.35, home: 3, kind: .planet(Color(hex: 0x9CA3AF), 7)),
        Feature(id: 8, fx: 0.08, fy: 0.84, depth: 0.28, home: 3, kind: .glow(Color(hex: 0x8FD3D9), 140)),
    ]

    /// Points of horizontal travel per page step, at depth 1.
    private static let step: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.features) { feature in
                    view(for: feature)
                        .offset(
                            x: CGFloat(feature.home - page) * Self.step * feature.depth,
                            // A touch of diagonal drift, alternating up/down
                            // so the field doesn't move as one sheet.
                            y: CGFloat(feature.home - page) * 16 * feature.depth
                                * (feature.id.isMultiple(of: 2) ? -0.6 : 0.6)
                        )
                        .opacity(opacity(of: feature))
                        .position(
                            x: geo.size.width * feature.fx,
                            y: geo.size.height * feature.fy
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func opacity(of feature: Feature) -> Double {
        let falloff = max(0, 1 - Double(abs(feature.home - page)) * 0.3)
        switch feature.kind {
        case .glow: return 0.5 * falloff
        case .planet, .ringed: return 0.9 * falloff
        }
    }

    @ViewBuilder
    private func view(for feature: Feature) -> some View {
        switch feature.kind {
        case let .planet(color, size):
            planetBody(color: color, size: size)
        case let .ringed(color, size):
            planetBody(color: color, size: size)
                .overlay(
                    Ellipse()
                        .stroke(color.opacity(0.55), lineWidth: 1.5)
                        .frame(width: size * 2.1, height: size * 0.8)
                        .rotationEffect(.degrees(-18))
                )
        case let .glow(color, size):
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size, height: size)
                .blur(radius: size / 3.2)
        }
    }

    /// A lit sphere: highlight pulled toward the upper left.
    private func planetBody(color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(
                colors: [color, color.opacity(0.45)],
                center: UnitPoint(x: 0.35, y: 0.3),
                startRadius: 0,
                endRadius: size
            ))
            .frame(width: size, height: size)
    }
}

/// Entrance treatment: fade in while drifting up, on a soft spring.
private struct OnboardingRise: ViewModifier {
    let on: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 16)
            .animation(.spring(duration: 0.55, bounce: 0.25).delay(delay), value: on)
    }
}

extension View {
    fileprivate func rise(_ on: Bool, delay: Double) -> some View {
        modifier(OnboardingRise(on: on, delay: delay))
    }
}
