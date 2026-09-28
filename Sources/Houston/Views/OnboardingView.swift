import SwiftUI

/// First-launch onboarding: a full-window takeover on the empty-state sky.
/// The window opens with no chrome at all: just the solar system and a
/// welcome headline. Continuing flies past the solar system into six
/// paginated steps laid open on the sky, two columns (2026-09-28): the
/// step's title and copy top-left, its live demo floating to the right —
/// Connect Your AI, Projects, Threads, Quick Tasks, Sharing, Live URL.
/// Each demo plays on its own, an animated pointer gliding to each control
/// and clicking it, and answers the user's own clicks. Shown until dismissed once
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
                stepPage
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

    // MARK: Step page

    /// The smallest size a demo is laid out at — below it the stage
    /// scales down whole instead of squeezing the vignette's layout.
    private static let stageMin = CGSize(width: 600, height: 400)
    private static let stageMax = CGSize(width: 780, height: 460)

    /// Two open columns on the sky, no enclosing card: the step's title
    /// and copy top-left, its demo floating to the right as its own
    /// window, controls along the bottom. Responsive to the window: under
    /// ~1060pt wide the text shrinks and stacks over the demo, and a
    /// window too small for the demo's minimum scales the demo down.
    private var stepPage: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1060
            let hPad: CGFloat = wide ? 56 : 32
            let content = min(geo.size.width - hPad * 2, 1200 - hPad * 2)
            let textWidth: CGFloat = wide ? (geo.size.width >= 1200 ? 320 : 280) : content
            // Vertical budget: titlebar clearance, footer band, and (when
            // stacked) the text block above the stage — kicker, title, ~3
            // lines of copy, and the gap.
            let chrome: CGFloat = 56 + 34 + 32 + 32
            let stackedText: CGFloat = 150
            let stage = CGSize(
                width: max(160, min(Self.stageMax.width,
                                    wide ? content - textWidth - 48 : content)),
                height: max(120, min(Self.stageMax.height,
                                     geo.size.height - chrome - (wide ? 0 : stackedText)))
            )
            VStack(spacing: 0) {
                Spacer(minLength: 56)
                Group {
                    if wide {
                        HStack(alignment: .top, spacing: 48) {
                            stepText(stacked: false).frame(width: textWidth, alignment: .leading)
                            stepStage(stage)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 22) {
                            stepText(stacked: true)
                            stepStage(stage)
                        }
                        .frame(width: Self.stageFit(stage).width)
                    }
                }
                .id(page)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 32)),
                    removal: .opacity.combined(with: .offset(x: -32))
                ))
                Spacer(minLength: 32)
                footer.frame(width: content)
            }
            .padding(.bottom, 32)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// The demo's layout size (never under `stageMin`) and the uniform
    /// scale that fits it into `size`.
    private static func stageLayout(_ size: CGSize) -> (layout: CGSize, scale: CGFloat) {
        let layout = CGSize(
            width: max(size.width, stageMin.width),
            height: max(size.height, stageMin.height)
        )
        return (layout, min(1, size.width / layout.width, size.height / layout.height))
    }

    /// What the stage actually occupies on screen at `size`.
    private static func stageFit(_ size: CGSize) -> CGSize {
        let (layout, scale) = stageLayout(size)
        return CGSize(width: layout.width * scale, height: layout.height * scale)
    }

    private func stepText(stacked: Bool) -> some View {
        let step = steps[max(0, min(page, steps.count - 1))]
        return VStack(alignment: .leading, spacing: stacked ? 8 : 14) {
            Text("STEP \(page + 1) OF \(steps.count)")
                .font(.system(size: stacked ? 10.5 : 11.5, weight: .semibold))
                .kerning(1)
                .foregroundStyle(Theme.link)
            Text(step.title)
                .font(.system(size: stacked ? 26 : 38, weight: .semibold))
                .tracking(stacked ? -0.6 : -1)
                .foregroundStyle(Theme.skyText)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.copy)
                .font(.system(size: stacked ? 13.5 : 15.5))
                .foregroundStyle(Theme.skyTextSecondary)
                .lineSpacing(stacked ? 3 : 5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: stacked ? 620 : .infinity, alignment: .leading)
                .padding(.top, stacked ? 0 : 4)
        }
        .padding(.top, stacked ? 0 : 6)
    }

    /// The demo window at `size`: laid out at no less than `stageMin`,
    /// scaled uniformly to fit when the window is smaller than that.
    private func stepStage(_ size: CGSize) -> some View {
        let step = steps[max(0, min(page, steps.count - 1))]
        let (layout, scale) = Self.stageLayout(size)
        return OnboardingStage(step: step, onDismiss: onDismiss)
            .frame(width: layout.width, height: layout.height)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.borderSidebar, lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.panelFill)
                    .shadow(color: Color.black.opacity(0.4), radius: 48, x: 0, y: 24)
            )
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: layout.width * scale, height: layout.height * scale,
                   alignment: .topLeading)
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
                    .fill(index == page ? Theme.link : Theme.skyTextSecondary.opacity(0.35))
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
    case connect, projects, threads, tasks, share, live

    var title: String {
        switch self {
        case .connect: "Connect Your AI"
        case .projects: "Projects"
        case .threads: "Threads"
        case .tasks: "Quick Tasks"
        case .share: "Sharing"
        case .live: "Live URL"
        }
    }

    /// Matter-of-fact copy: what the thing is and what a click does.
    var copy: String {
        switch self {
        case .connect:
            "Sign in with the subscriptions you already have, or run models "
                + "on your Mac. Change any of this later from a chat's model menu."
        case .projects:
            "Add a project from your file browser, then open a chat or a terminal "
                + "in it. Move on while the agent works: Houston notifies you the "
                + "moment a chat needs your attention."
        case .threads:
            "Select any part of a reply and right-click to ask about just "
                + "that. The quote stays highlighted with its reply count, and "
                + "the thread opens beside the chat while the conversation stays put."
        case .tasks:
            "Highlight any text and press \u{2318}S to save it as a task. It "
                + "lands under the open project, and the tasks menu opens to show it."
        case .share:
            "A running dev server is reachable from any device on your Wi-Fi "
                + "at project.local, with a QR code for phones."
        case .live:
            "Turn on Live URL and a running dev server gets its own public https "
                + "link, like \(LiveURLVignette.host). Open it on cellular or send it "
                + "to anyone. Live URLs are part of Houston Pro."
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
            case .tasks: QuickTaskVignette()
            case .share: ShareVignette()
            case .live: LiveURLVignette()
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
            // Nothing else scans for MLX Core until a chat's model menu
            // opens, so without this the row sat at "unknown" forever.
            localModels.refresh()
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
            } else if installed == nil {
                Text("Checking…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else if installed == false {
                OnbButton(installHint) { Actions.openExternal(installURL) }
            } else {
                OnbButton("Sign in", action: signIn)
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

// MARK: - Demo cursor

/// Where the demo cursor can go: each vignette tags its clickable bits
/// with `.demoTarget(id)`, and the cursor glides to the tagged view's
/// center — anchors, not hard-coded offsets, so it lands true at every
/// stage size.
private struct DemoTargetKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(
        value: inout [String: Anchor<CGRect>],
        nextValue: () -> [String: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    fileprivate func demoTarget(_ id: String) -> some View {
        anchorPreference(key: DemoTargetKey.self, value: .bounds) { [id: $0] }
    }

    /// The pointer over a vignette: aimed at `target` (a `.demoTarget`
    /// id anywhere inside, overlays included), pressing on each `clicks`
    /// bump. Never intercepts a click.
    fileprivate func demoCursor(_ target: String?, clicks: Int) -> some View {
        overlayPreferenceValue(DemoTargetKey.self) { anchors in
            GeometryReader { geo in
                DemoCursor(
                    target: target.flatMap { anchors[$0] }.map { anchor in
                        let rect = geo[anchor]
                        return CGPoint(x: rect.midX, y: rect.midY)
                    },
                    clicks: clicks,
                    rest: CGPoint(x: geo.size.width * 0.78, y: geo.size.height * 0.86)
                )
            }
            .allowsHitTesting(false)
        }
    }
}

/// A macOS arrow pointer that glides between targets and shows each click
/// as a quick press plus an accent ripple at the tip.
private struct DemoCursor: View {
    let target: CGPoint?
    let clicks: Int
    let rest: CGPoint

    @State private var point: CGPoint?
    @State private var ripple: CGFloat = 1
    @State private var pressed = false

    var body: some View {
        let at = point ?? rest
        ZStack {
            Circle()
                .stroke(Theme.link, lineWidth: 2)
                .frame(width: 34, height: 34)
                .scaleEffect(0.25 + ripple * 0.85)
                .opacity(Double(1 - ripple) * 0.9)
                .position(at)
            CursorArrow()
                .fill(Color.black)
                .overlay(CursorArrow().stroke(Color.white, lineWidth: 1.3))
                .frame(width: 13, height: 20)
                .scaleEffect(pressed ? 0.84 : 1, anchor: .topLeading)
                .shadow(color: .black.opacity(0.35), radius: 2.5, x: 0, y: 1.5)
                // The frame's top-left corner is the arrow's tip.
                .position(x: at.x + 6.5, y: at.y + 10)
        }
        .onAppear {
            // Start at rest and glide in, rather than popping onto the
            // first target.
            if let target {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.8)) { point = target }
                }
            }
        }
        .onChange(of: target) { _, new in
            guard let new else { return }
            withAnimation(.easeInOut(duration: 0.75)) { point = new }
        }
        .onChange(of: clicks) {
            ripple = 0
            withAnimation(.easeOut(duration: 0.12)) { pressed = true }
            withAnimation(.easeOut(duration: 0.55)) { ripple = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeOut(duration: 0.14)) { pressed = false }
            }
        }
    }
}

/// The classic arrow, drawn in a 13×20 box with the tip at the origin.
private struct CursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 13, sy = rect.height / 20
        let pts: [(CGFloat, CGFloat)] = [
            (0.5, 0.5), (0.5, 16.5), (4.3, 12.9), (6.8, 18.9),
            (9.2, 17.9), (6.7, 12.0), (12.0, 12.0),
        ]
        var path = Path()
        path.move(to: CGPoint(x: pts[0].0 * sx, y: pts[0].1 * sy))
        for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.0 * sx, y: p.1 * sy)) }
        path.closeSubpath()
        return path
    }
}

/// A vignette's autoplay: per phase, linger `dwell`, glide the cursor
/// through that phase's waypoints (hovering each, clicking the LAST),
/// then advance. A phase with no waypoints just advances after its dwell
/// — things that happen on their own. A user click that advances first
/// wins: the loop sees the phase moved and starts over from the new one.
@MainActor
private func runDemo(
    phase: () -> Int,
    beat: (Int) -> (dwell: Double, path: [String]),
    aim: (String) -> Void,
    click: () -> Void,
    advance: () -> Void
) async {
    while !Task.isCancelled {
        let current = phase()
        let (dwell, path) = beat(current)
        try? await Task.sleep(for: .seconds(dwell))
        for id in path {
            guard phase() == current, !Task.isCancelled else { break }
            aim(id)
            try? await Task.sleep(for: .seconds(0.85))
        }
        guard phase() == current, !Task.isCancelled else { continue }
        if !path.isEmpty {
            click()
            try? await Task.sleep(for: .seconds(0.22))
            guard phase() == current else { continue }
        }
        advance()
    }
}

// MARK: - Mini chrome

/// The vignettes' shared pieces — the app's own grammar, near full size.
private enum Mini {
    static let page = Color(light: 0xF4F4F5, dark: 0x0B0B0D)
    static let bar = Color(light: 0xFFFFFF, dark: 0x18181B)
    static let bubble = Theme.chatUserFill
    /// Text selection wash (the system's, near enough) for the demo.
    static let selection = Color(light: 0xB4D5FE, dark: 0x3B5A8A)

    static func control(_ icon: String) -> some View {
        LucideIcon(icon, size: 13)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.buttonFill))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderSidebar, lineWidth: 1))
            .contentShape(Rectangle())
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
            .onTapGesture(perform: action)
    }

    static func menuDivider() -> some View {
        Rectangle().fill(Theme.borderSidebar).frame(height: 1).padding(.vertical, 3)
    }
}

// MARK: - Projects

/// Add a project → open a chat from its row's hover icons → the chat's
/// workspace (top bar + side panel, adding a terminal from the panel) →
/// move on → get called back → answer with Auto. Plays on its own with
/// the pointer doing the clicking; clicks jump ahead.
private struct ProjectsVignette: View {
    /// 0 idle · 1 folder picker · 2 showcase added, hovered (row icons) ·
    /// 3 new chat open, working · 4 terminal added from the side panel ·
    /// 5 user elsewhere · 6 needs-you banner · 7 back on the approval ·
    /// 8 answered with Auto.
    @State private var phase = 0
    @State private var aim: String?
    @State private var clicks = 0

    private var projects: [String] {
        phase >= 2 ? ["hierarch", "portfolio", "showcase"] : ["hierarch", "portfolio"]
    }
    /// The project on screen.
    private var shown: String { [3, 4, 7, 8].contains(phase) ? "showcase" : "hierarch" }
    /// showcase's chat has a turn running.
    private var working: Bool { (3...5).contains(phase) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            page
        }
        .background(Mini.page)
        .overlay { if phase == 1 { picker.transition(.opacity.combined(with: .scale(scale: 0.97))) } }
        .overlay(alignment: .topTrailing) {
            if phase == 6 {
                banner
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .demoCursor(aim, clicks: clicks)
        .task {
            await runDemo(
                phase: { phase },
                beat: { p in
                    switch p {
                    case 0: (1.0, ["add"])
                    case 1: (0.5, ["open"])
                    case 2: (0.4, ["row-showcase", "new-chat"])
                    case 3: (1.3, ["add-terminal"])
                    case 4: (1.2, ["row-hierarch"])
                    case 5: (1.8, [])
                    case 6: (0.7, ["banner"])
                    case 7: (0.9, ["auto"])
                    default: (2.4, [])
                    }
                },
                aim: { aim = $0 },
                click: { clicks += 1 },
                advance: advance
            )
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Mini.caps("PROJECTS").padding(.leading, 10).padding(.bottom, 6)
            ForEach(projects, id: \.self) { row($0) }
            HStack(spacing: 8) {
                LucideIcon("folder-plus", size: 14).foregroundStyle(Theme.textSecondary)
                Text("Add a project").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .demoTarget("add")
            .onTapGesture { if phase == 0 { advance() } }
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .frame(width: 184)
        .frame(maxHeight: .infinity)
        .background(Mini.bar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.borderSidebar).frame(width: 1) }
    }

    /// A project row as the sidebar draws it: package glyph, name, and on
    /// hover the two quick actions — "+" New chat, terminal New terminal.
    private func row(_ name: String) -> some View {
        let hovered = name == "showcase" && phase == 2
        let waiting = name == "showcase" && phase == 6
        return HStack(spacing: 9) {
            LucideIcon("package", size: 14).foregroundStyle(Theme.textSecondary)
            Text(name).font(.system(size: 13.5)).foregroundStyle(Theme.text.opacity(0.85))
            Spacer(minLength: 0)
            if hovered {
                HStack(spacing: 1) {
                    LucideIcon("plus", size: 14)
                        .foregroundStyle(Theme.text)
                        .frame(width: 20, height: 20)
                        .demoTarget("new-chat")
                        .onTapGesture { advance() }
                    LucideIcon("square-terminal", size: 14)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 20, height: 20)
                }
                .transition(.opacity)
            } else if name == "showcase", working {
                Circle().fill(Theme.dotActive).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(name == shown ? Theme.rowSelected
                    : hovered ? Theme.rowHovered
                    : waiting ? Theme.buttonActiveFill : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .demoTarget("row-\(name)")
        .transition(.opacity.combined(with: .offset(y: -6)))
        .onTapGesture {
            if name == "hierarch", phase == 4 { advance() }
            if waiting { advance() }
        }
    }

    // MARK: Page

    /// The project's workspace: the floating top bar, the chat, and the
    /// side panel hanging on the right.
    private var page: some View {
        VStack(spacing: 12) {
            topBar
            HStack(alignment: .top, spacing: 12) {
                chat
                sidePanel
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The pill over every workspace: project ▾, the branch chip, Tasks.
    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Text(shown.capitalized).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                LucideIcon("chevron-down", size: 11).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 5) {
                LucideIcon("git-branch", size: 12)
                Circle().fill(Theme.dotActive).frame(width: 5, height: 5)
                Text("main").font(.system(size: 12))
            }
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 5) {
                LucideIcon("list-checks", size: 12)
                Text("Tasks").font(.system(size: 12))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10).fill(Mini.bar))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderSidebar, lineWidth: 1))
        .animation(nil, value: shown)
    }

    // MARK: Chat

    @ViewBuilder
    private var chat: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shown == "hierarch" {
                bubble("Tighten the empty state copy")
                Text("Done. The headline is shorter and the button says what it does.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text).lineSpacing(3)
            } else {
                bubble("Add a pricing page with monthly and yearly plans")
                switch phase {
                case 7: approval
                case 8:
                    HStack(spacing: 6) {
                        LucideIcon("square-terminal", size: 12)
                        Text("Ran npm install @stripe/stripe-js").font(.system(size: 11.5, design: .monospaced))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    Text("Installed. Building the pricing page now.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.text)
                default:
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Working…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The approval prompt as the chat now draws it: the composer's wash,
    /// no border — Allow, Auto, Deny.
    private var approval: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Claude wants to run a command")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Text("npm install @stripe/stripe-js")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Text("Allow").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 11).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ctaFill))
                HStack(spacing: 4) {
                    LucideIcon("zap", size: 11)
                    Text("Auto").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.rowHovered))
                .demoTarget("auto")
                .onTapGesture { advance() }
                Text("Deny").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
            }
            .padding(.top, 2)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sidebarFill.opacity(0.6)))
        .transition(.opacity)
    }

    /// The composer's resting bar — its mode chip flips to Auto edits
    /// once the approval's Auto is taken.
    private var composer: some View {
        HStack(spacing: 8) {
            Text("What's next?").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if phase == 8 { LucideIcon("zap", size: 10) }
                Text(phase == 8 ? "Auto edits" : "Ask first").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(phase == 8 ? Theme.link : Theme.textSecondary)
            Circle().fill(Theme.ctaFill).frame(width: 22, height: 22)
                .overlay(LucideIcon("arrow-up", size: 11).foregroundStyle(.white))
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.sidebarFill.opacity(0.6)))
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5)).foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Mini.bubble))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Side panel

    /// The workspace's side panel: one card per item, each header with
    /// its "+" — adding a terminal (or chat) happens right here.
    private var sidePanel: some View {
        VStack(spacing: 10) {
            panelCard("TERMINALS", addTarget: "add-terminal") {
                if shown == "hierarch" {
                    panelRow("zsh", dot: Theme.dotShell)
                } else if phase >= 4 {
                    panelRow("zsh", dot: Theme.dotShell).transition(.opacity.combined(with: .offset(y: -4)))
                } else {
                    Text("No terminals open").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6).frame(height: 24)
                }
            }
            panelCard("CHATS", addTarget: nil) {
                if shown == "hierarch" {
                    panelRow("Empty state copy", dot: Theme.dotIdle)
                } else {
                    panelRow("Pricing page", dot: working || phase == 7 ? Theme.dotActive : Theme.dotIdle)
                }
            }
        }
        .frame(width: 168)
    }

    private func panelCard<Content: View>(
        _ title: String, addTarget: String?, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Mini.caps(title)
                Spacer(minLength: 0)
                LucideIcon("plus", size: 12)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlChip))
                    .modifier(OptionalDemoTarget(id: addTarget))
                    .onTapGesture { if addTarget != nil, phase == 3 { advance() } }
                LucideIcon("dock-top", size: 12)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlChip))
            }
            content()
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 11).fill(Mini.bar))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.borderSidebar, lineWidth: 1))
    }

    private func panelRow(_ title: String, dot: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
    }

    // MARK: Overlays

    /// The system folder picker, drawn small: a few folders, one chosen.
    private var picker: some View {
        ZStack {
            Color.black.opacity(0.18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Add a project")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .padding(.bottom, 10)
                VStack(spacing: 2) {
                    ForEach(["hierarch", "portfolio", "showcase", "spicy-resume"], id: \.self) { name in
                        HStack(spacing: 8) {
                            LucideIcon("folder", size: 14)
                                .foregroundStyle(name == "showcase" ? Color.white : Theme.link)
                            Text(name).font(.system(size: 12.5))
                                .foregroundStyle(name == "showcase" ? Color.white : Theme.text)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(name == "showcase" ? Theme.ctaFill : .clear))
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Mini.page))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderSidebar, lineWidth: 1))
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Text("Cancel").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.buttonFill))
                    Text("Open").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ctaFill))
                        .contentShape(Rectangle())
                        .demoTarget("open")
                        .onTapGesture { advance() }
                }
                .padding(.top, 12)
            }
            .padding(16)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.menuFill)
                    .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderSidebar, lineWidth: 1))
        }
    }

    /// The macOS banner a needs-you event raises.
    private var banner: some View {
        HStack(alignment: .top, spacing: 10) {
            SVGIcon(name: "rocket", size: 16)
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ctaFill))
            VStack(alignment: .leading, spacing: 2) {
                Text("showcase needs you")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Claude is waiting for permission to run npm install.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 270, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.menuFill)
                .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.borderSidebar, lineWidth: 1))
        .contentShape(Rectangle())
        .demoTarget("banner")
        .onTapGesture { advance() }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
            phase = (phase + 1) % 9
        }
    }
}

/// `.demoTarget` only when there's an id — for shared chrome where just
/// one instance is the cursor's target.
private struct OptionalDemoTarget: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.demoTarget(id) } else { content }
    }
}

// MARK: - Threads

/// A reply at full size: select a run of text → right-click → "Ask About"
/// → the thread opens beside it with the quote split out, reply count
/// under the quoted words. Plays on its own with the pointer doing the
/// clicking; clicks jump ahead.
private struct ThreadVignette: View {
    /// 0 idle · 1 selection · 2 context menu · 3 thread open, question
    /// waiting · 4 sent and answered.
    @State private var phase = 0
    @State private var aim: String?
    @State private var clicks = 0

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
                    // The context menu hangs off this paragraph and must
                    // draw over the one below it.
                    .zIndex(1)
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
        .demoCursor(aim, clicks: clicks)
        .task {
            await runDemo(
                phase: { phase },
                beat: { p in
                    switch p {
                    case 0: (1.0, ["quote"])
                    case 1: (0.6, ["quote"])
                    case 2: (0.5, ["ask"])
                    case 3: (0.9, ["send"])
                    default: (2.4, ["close"])
                    }
                },
                aim: { aim = $0 },
                click: { clicks += 1 },
                advance: advance
            )
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
            Text(selectable)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineSpacing(3)
                .contentShape(Rectangle())
                .demoTarget("quote")
                .onTapGesture { if phase <= 1 { advance() } }
                .overlay(alignment: .bottomLeading) {
                    if phase == 2 {
                        Mini.menu {
                            Mini.menuRow("Ask About \u{201C}stale-while-revalidate…\u{201D}", hint: true) { advance() }
                                .demoTarget("ask")
                            Mini.menuRow("Copy") {}
                        }
                        .frame(width: 270)
                        .offset(x: 110, y: 64)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    }
                }
        }
    }

    /// The middle paragraph with the selection wash on the quoted run
    /// (phase 1+) — an attributed run, so it tracks the text at any width.
    private var selectable: AttributedString {
        var out = AttributedString(before)
        var run = AttributedString(quote)
        if phase >= 1 { run.backgroundColor = Mini.selection }
        out += run
        out += AttributedString(after)
        return out
    }

    private var threadPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Mini.caps("THREAD")
                Spacer(minLength: 0)
                Mini.control("x").demoTarget("close").onTapGesture { reset() }
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
                    .demoTarget("send")
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

// MARK: - Quick tasks

/// A reply with a follow-up buried in it: select the run → ⌘S → the
/// tasks menu drops from the titlebar with the run as its newest task.
/// Plays on its own (the pointer selects, the keys press); the keys jump
/// ahead.
private struct QuickTaskVignette: View {
    /// 0 idle · 1 selection, keys waiting · 2 saved, tasks menu open.
    @State private var phase = 0
    @State private var aim: String?
    @State private var clicks = 0

    private let before = "Auth is wired and the suite passes. One follow-up: "
    private let quote = "move the rate limiter into middleware before launch"
    private let after = ", it's still per-route."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The titlebar strip: the tasks glyph the menu hangs off.
            HStack {
                Spacer(minLength: 0)
                Mini.control("list-checks")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Mini.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.borderSidebar).frame(height: 1) }

            VStack(alignment: .leading, spacing: 14) {
                Mini.caps("CLAUDE")
                Text(reply)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .frame(maxWidth: 400, alignment: .leading)
                    .contentShape(Rectangle())
                    .demoTarget("run")
                    .onTapGesture { if phase == 0 { advance() } }
                Text("Want me to open a branch for the middleware change?")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .frame(maxWidth: 400, alignment: .leading)
                Spacer(minLength: 0)
                keys.frame(maxWidth: 400)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Mini.page)
        .overlay(alignment: .topTrailing) {
            if phase == 2 {
                tasksMenu
                    .frame(width: 290)
                    .padding(.top, 36)
                    .padding(.trailing, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .demoCursor(aim, clicks: clicks)
        .task {
            // The pointer selects the run; ⌘S and the menu happen on
            // their own (keys, not clicks).
            await runDemo(
                phase: { phase },
                beat: { p in
                    switch p {
                    case 0: (1.0, ["run"])
                    case 1: (1.1, [])
                    default: (3.2, [])
                    }
                },
                aim: { aim = $0 },
                click: { clicks += 1 },
                advance: advance
            )
        }
    }

    /// The reply with the selection wash on the quoted run (phase 1+).
    private var reply: AttributedString {
        var out = AttributedString(before)
        var run = AttributedString(quote)
        if phase >= 1 { run.backgroundColor = Mini.selection }
        out += run
        out += AttributedString(after)
        return out
    }

    /// ⌘ S keycaps: quiet until there's a selection, ringed while they're
    /// the next click, pressed once the task is saved.
    private var keys: some View {
        HStack(spacing: 6) {
            keycap("\u{2318}")
            keycap("S")
            Text(phase == 2 ? "Saved to Tasks" : "Add selection to Tasks")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 4)
        }
        .opacity(phase == 0 ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if phase == 1 { advance() } }
    }

    private func keycap(_ glyph: String) -> some View {
        Text(glyph)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(phase == 2 ? .white : Theme.text)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(phase == 2 ? Theme.link : Mini.bar))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.borderSidebar, lineWidth: 1))
            .shadow(color: Color.black.opacity(phase == 2 ? 0 : 0.12), radius: 0, x: 0, y: 2)
            .scaleEffect(phase == 2 ? 0.94 : 1)
    }

    /// The titlebar tasks menu, as the app draws it: caps header, the
    /// project's group, the new task on top with a fading accent wash.
    private var tasksMenu: some View {
        VStack(alignment: .leading, spacing: 6) {
            Mini.caps("TASKS").padding(.horizontal, 4)
            Text("HIERARCH")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.top, 4)
            taskRow(quote, fresh: true)
            taskRow("Fix the flaky webhook retry test", fresh: false)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.menuFill)
                .shadow(color: Color.black.opacity(0.25), radius: 14, x: 0, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.borderSidebar, lineWidth: 1))
    }

    private func taskRow(_ text: String, fresh: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            LucideIcon("circle", size: 13)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(fresh ? Theme.link.opacity(0.1) : Mini.page)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(fresh ? Theme.link.opacity(0.5) : Theme.borderSidebar, lineWidth: 1)
        )
    }

    private func advance() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            phase = (phase + 1) % 3
        }
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

// MARK: - Live URL

/// The server card's Live URL switch at full size: flip it, it connects,
/// and a phone on cellular (no Wi-Fi) loads the public link. Plays on its
/// own with the pointer flipping the switch; the switch jumps ahead.
private struct LiveURLVignette: View {
    /// 0 off · 1 connecting · 2 online, the phone loaded.
    @State private var phase = 0
    @State private var aim: String?
    @State private var clicks = 0
    /// The relay's own name format (adjective-noun-suffix, houston-relay
    /// names.go), so the demo shows the link a user actually gets.
    static let host = "crimson-nebula-x4k2." + RelayTunnelStore.relayHost
    private var host: String { Self.host }

    var body: some View {
        HStack(spacing: 48) {
            card
            VStack(spacing: 12) {
                phone
                HStack(spacing: 6) {
                    LucideIcon("signal-high", size: 13)
                    Text("Anywhere, not just your Wi-Fi").font(.system(size: 12))
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Mini.page)
        .demoCursor(aim, clicks: clicks)
        .task {
            await runDemo(
                phase: { phase },
                beat: { p in
                    switch p {
                    case 0: (1.2, ["switch"])
                    case 1: (1.4, [])
                    default: (3.4, [])
                    }
                },
                aim: { aim = $0 },
                click: { clicks += 1 },
                advance: advance
            )
        }
    }

    // MARK: Server card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hierarch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 14)
            row("Browser", subtitle: "Localhost:5173") {
                SVGIcon(name: "redirect", size: 16).foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, 14)
            hairline
            row("Local WiFi sharing", subtitle: "hierarch.local") {
                miniSwitch(true)
            }
            .padding(.vertical, 14)
            hairline
            row("Live URL", subtitle: liveSubtitle, live: phase == 2) {
                if phase == 2 {
                    LucideIcon("copy", size: 14)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .transition(.opacity)
                }
                miniSwitch(phase > 0)
                    .contentShape(Capsule())
                    .demoTarget("switch")
                    .onTapGesture { phase == 0 ? advance() : reset() }
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 12).fill(Mini.bar))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderSidebar, lineWidth: 1))
    }

    private var liveSubtitle: String {
        switch phase {
        case 1: "Connecting…"
        default: host
        }
    }

    private func row<Trailing: View>(
        _ title: String, subtitle: String, live: Bool = false,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 5) {
                    if live {
                        Circle().fill(Theme.dotActive).frame(width: 6, height: 6)
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(live ? Theme.link : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) { trailing() }
        }
    }

    /// `PanelSwitchStyle`'s look, drawn static for the demo.
    private func miniSwitch(_ on: Bool) -> some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Theme.switchTrackOn : Theme.switchTrack)
                .frame(width: 38, height: 22)
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .padding(3)
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.borderSidebar).frame(height: 1)
    }

    // MARK: Phone

    private var phone: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("9:41").font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                LucideIcon("signal-high", size: 10)
                Text("5G").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 4) {
                LucideIcon("lock", size: 9)
                Text(host).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Theme.buttonFill))
            .padding(.horizontal, 10)
            .padding(.top, 8)

            ZStack {
                switch phase {
                case 2:
                    site.transition(.opacity.combined(with: .offset(y: 8)))
                case 1:
                    ProgressView().controlSize(.small).transition(.opacity)
                default:
                    VStack(spacing: 6) {
                        LucideIcon("globe", size: 20)
                        Text("Not live yet").font(.system(size: 10.5))
                    }
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 184, height: 320)
        .background(RoundedRectangle(cornerRadius: 26).fill(Mini.page))
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(Theme.text.opacity(0.85), lineWidth: 4)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 8)
    }

    /// The dev site, as the phone renders it once the link is live.
    private var site: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(
                    colors: [Theme.link, Theme.link.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(height: 84)
                .overlay(alignment: .bottomLeading) {
                    Text("Hierarch")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(10)
                }
            ForEach([1.0, 0.85, 0.6], id: \.self) { width in
                Capsule()
                    .fill(Theme.textSecondary.opacity(0.22))
                    .frame(height: 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, anchor: .leading)
            }
            Text("Book a demo")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ctaFill))
                .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private func advance() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            phase = (phase + 1) % 3
        }
    }

    private func reset() {
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) { phase = 0 }
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

    /// Placed around the edges of the two-column page: planets keep off
    /// the text column (top-left) and out from behind the demo (right),
    /// sitting in the top band, the bottom band, and the far left edge;
    /// only soft glows sit behind content. The fade-out over distance
    /// keeps travel from carrying a feature anywhere visible far from home.
    private static let features: [Feature] = [
        Feature(id: 0, fx: 0.10, fy: 0.22, depth: 0.25, home: 0, kind: .glow(Color(hex: 0xD97757), 150)),
        Feature(id: 1, fx: 0.92, fy: 0.07, depth: 0.70, home: 0, kind: .planet(Color(hex: 0x8FD3D9), 18)),
        Feature(id: 2, fx: 0.12, fy: 0.78, depth: 0.50, home: 1, kind: .planet(Color(hex: 0xE0C084), 11)),
        Feature(id: 3, fx: 0.93, fy: 0.92, depth: 0.85, home: 1, kind: .ringed(Color(hex: 0xD9C27E), 24)),
        Feature(id: 4, fx: 0.92, fy: 0.28, depth: 0.30, home: 2, kind: .glow(Color(hex: 0x5069D9), 130)),
        Feature(id: 5, fx: 0.05, fy: 0.66, depth: 0.60, home: 2, kind: .planet(Color(hex: 0x4A90D9), 14)),
        Feature(id: 12, fx: 0.11, fy: 0.62, depth: 0.40, home: 3, kind: .glow(Color(hex: 0xB07AD9), 130)),
        Feature(id: 13, fx: 0.70, fy: 0.06, depth: 0.65, home: 3, kind: .planet(Color(hex: 0x7FBF8E), 13)),
        Feature(id: 6, fx: 0.62, fy: 0.93, depth: 0.45, home: 4, kind: .planet(Color(hex: 0xD9603B), 9)),
        Feature(id: 7, fx: 0.42, fy: 0.07, depth: 0.35, home: 4, kind: .planet(Color(hex: 0x9CA3AF), 7)),
        Feature(id: 8, fx: 0.08, fy: 0.84, depth: 0.28, home: 4, kind: .glow(Color(hex: 0x8FD3D9), 140)),
        Feature(id: 9, fx: 0.90, fy: 0.20, depth: 0.30, home: 5, kind: .glow(Color(hex: 0xD97757), 140)),
        Feature(id: 10, fx: 0.06, fy: 0.72, depth: 0.75, home: 5, kind: .planet(Color(hex: 0x3F86D9), 16)),
        Feature(id: 11, fx: 0.86, fy: 0.93, depth: 0.55, home: 5, kind: .planet(Color(hex: 0xC98F4C), 12)),
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
            PlanetSphere(
                color: color, size: size,
                atmosphere: size >= 14 ? color : nil,
                lightFrom: light(for: feature)
            )
        case let .ringed(color, size):
            PlanetSphere(
                color: color, size: size,
                bands: [0xE8D6A6, 0xD4B676, 0xE8D6A6, 0xC9A968, 0xE8D6A6].map { Color(hex: $0) },
                ring: color,
                lightFrom: light(for: feature)
            )
        case let .glow(color, size):
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size, height: size)
                .blur(radius: size / 3.2)
        }
    }

    /// Every body is lit from the middle of the sky, where the card sits
    /// (widths scaled up a little for the landscape pane).
    private func light(for feature: Feature) -> Angle {
        .radians(atan2(Double(0.5 - feature.fy), Double((0.5 - feature.fx) * 1.5)))
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
