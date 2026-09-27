import SwiftUI

/// First-launch onboarding: a full-window takeover on the empty-state sky.
/// The window opens with no chrome at all: just the solar system and a
/// welcome headline. Taking the tour flies past the solar system and walks
/// one spacious page per section of the app across the same sky, each page
/// with its own parallax set dressing under a spotlight gradient. Shown
/// until dismissed once (`onboardingSeen`), replayable from the footer
/// gear. Replaced the centered-card dialog (2026-08-25), which replaced
/// the three-card WelcomeView.
struct OnboardingView: View {
    let onDismiss: () -> Void

    /// -1 is the welcome screen; 0..<pages.count are the tour pages.
    @State private var page = -1
    @State private var appeared = false
    private let pages = OnboardingPage.all
    private var inTour: Bool { page >= 0 }
    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        ZStack {
            NightSky()

            // The solar system belongs to the welcome screen; entering the
            // tour flies past it entirely and the per-page decor takes over.
            SolarSystem()
                .scaleEffect(inTour ? 1.6 : 1)
                .opacity(inTour ? 0 : 1)
                // Lifted on the welcome screen so the system and the headline
                // below it read as one vertically balanced composition. The
                // empty state underneath starts with the same lift while the
                // sidebar is hidden, so the dismissal crossfade is static —
                // the glide down to center happens on the other side, in one
                // motion with the sidebar slide.
                .offset(y: inTour ? 0 : -56)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .rise(appeared, delay: 0)

            // Deep-space set dressing for the tour, trailing the page swaps
            // on its own slightly laggier spring for the parallax feel.
            ParallaxSpace(page: max(0, page))
                .opacity(inTour ? 1 : 0)
                .animation(.spring(duration: 0.65, bounce: 0.14), value: page)

            // Spotlight: a soft radial falloff dims the periphery and holds
            // the eye on the page content.
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.3)],
                center: .center,
                startRadius: 170,
                endRadius: 780
            )
            .opacity(inTour ? 1 : 0)
            .allowsHitTesting(false)

            if inTour {
                tour
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

    /// The headline sits below the solar system, mirroring the empty state's
    /// quiet bottom text — but bigger, with the tour invitation under it.
    private var welcome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text("Welcome to Houston")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.skyText)
                Text("Mission control for your coding agents.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.skyTextSecondary)
            }
            .rise(appeared, delay: 0.35)

            VStack(spacing: 14) {
                Button {
                    go(to: 0)
                } label: {
                    Text("Take the Tour")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.ctaFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                quietButton("Skip the tour and jump right in", action: onDismiss)
            }
            .padding(.top, 32)
            .rise(appeared, delay: 0.55)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 80)
    }

    // MARK: Tour

    private var tour: some View {
        // Clamped: the outgoing tour view can be re-evaluated mid-transition
        // after Back has already set `page` to -1 (the welcome screen).
        let shown = pages[max(0, min(page, pages.count - 1))]
        return VStack(spacing: 0) {
            Spacer(minLength: 32)

            // The page swaps as one unit; fixed heights inside keep the
            // layout from resizing between pages.
            VStack(spacing: 0) {
                OnboardingStage(kind: shown.stage)
                Text(shown.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.skyText)
                    .padding(.top, 30)
                Text(shown.copy)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.skyTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
                    .frame(height: 64, alignment: .top)
                    .padding(.top, 12)
            }
            .frame(width: 620)
            .id(page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 32)),
                removal: .opacity.combined(with: .offset(x: -32))
            ))

            Spacer(minLength: 20)

            dots
            controls
                .frame(maxWidth: 620)
                .padding(.top, 30)
                .padding(.bottom, 52)
        }
        .frame(maxWidth: .infinity)
    }

    /// Active page: a wide capsule in the sky text color so it reads on the
    /// black sky in both appearances.
    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.skyText : Theme.skyText.opacity(0.35))
                    .frame(width: index == page ? 16 : 6, height: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { go(to: index) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: page)
    }

    private var controls: some View {
        HStack {
            if !isLast {
                quietButton("Skip", action: onDismiss)
            }
            Spacer()
            quietButton("Back") { go(to: page - 1) }
            Button {
                isLast ? onDismiss() : go(to: page + 1)
            } label: {
                Text(isLast ? "Start Exploring" : "Next")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Theme.ctaFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.skyTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Crossing the welcome/tour boundary (either direction) rides the slow
    /// spring that also recedes or restores the solar system; page-to-page
    /// hops inside the tour stay quick.
    private func go(to index: Int) {
        let crossing = inTour != (index >= 0)
        withAnimation(
            crossing ? .spring(duration: 0.8, bounce: 0.12)
                     : .easeOut(duration: 0.28)
        ) {
            page = index
        }
    }
}

/// Decorative deep space behind the tour pages: small planets, soft glows,
/// and a ringed body scattered around the periphery, each pinned to a home
/// page. As the tour advances they slide opposite the page motion, nearer
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

    /// Placed on the left/right bands so nothing drifts under the content
    /// column; the fade-out over distance keeps travel from carrying a
    /// feature anywhere visible far from home.
    private static let features: [Feature] = [
        Feature(id: 0, fx: 0.13, fy: 0.22, depth: 0.25, home: 0, kind: .glow(Color(hex: 0xD97757), 150)),
        Feature(id: 1, fx: 0.86, fy: 0.17, depth: 0.70, home: 0, kind: .planet(Color(hex: 0x8FD3D9), 18)),
        Feature(id: 2, fx: 0.20, fy: 0.72, depth: 0.50, home: 1, kind: .planet(Color(hex: 0xE0C084), 11)),
        Feature(id: 3, fx: 0.88, fy: 0.68, depth: 0.85, home: 1, kind: .ringed(Color(hex: 0xD9C27E), 24)),
        Feature(id: 4, fx: 0.90, fy: 0.28, depth: 0.30, home: 2, kind: .glow(Color(hex: 0x5069D9), 130)),
        Feature(id: 5, fx: 0.13, fy: 0.40, depth: 0.60, home: 2, kind: .planet(Color(hex: 0x4A90D9), 14)),
        Feature(id: 6, fx: 0.83, fy: 0.84, depth: 0.45, home: 3, kind: .planet(Color(hex: 0xD9603B), 9)),
        Feature(id: 7, fx: 0.28, fy: 0.10, depth: 0.35, home: 3, kind: .planet(Color(hex: 0x9CA3AF), 7)),
        Feature(id: 8, fx: 0.10, fy: 0.84, depth: 0.28, home: 4, kind: .glow(Color(hex: 0x8FD3D9), 140)),
        Feature(id: 9, fx: 0.90, fy: 0.13, depth: 0.75, home: 4, kind: .planet(Color(hex: 0xC98F4C), 22)),
        Feature(id: 10, fx: 0.15, fy: 0.58, depth: 0.55, home: 5, kind: .ringed(Color(hex: 0x8FD3D9), 15)),
        Feature(id: 11, fx: 0.87, fy: 0.47, depth: 0.50, home: 5, kind: .planet(Color(hex: 0xD9C27E), 11)),
        Feature(id: 12, fx: 0.23, fy: 0.87, depth: 0.40, home: 6, kind: .planet(Color(hex: 0x4A90D9), 8)),
        Feature(id: 13, fx: 0.85, fy: 0.78, depth: 0.30, home: 6, kind: .glow(Color(hex: 0xD97757), 120)),
        Feature(id: 14, fx: 0.12, fy: 0.30, depth: 0.65, home: 7, kind: .planet(Color(hex: 0xE0C084), 13)),
        Feature(id: 15, fx: 0.88, fy: 0.20, depth: 0.35, home: 7, kind: .glow(Color(hex: 0x5069D9), 140)),
        Feature(id: 16, fx: 0.18, fy: 0.75, depth: 0.80, home: 8, kind: .ringed(Color(hex: 0x8FD3D9), 20)),
        Feature(id: 17, fx: 0.86, fy: 0.62, depth: 0.45, home: 8, kind: .planet(Color(hex: 0xD9603B), 10)),
        Feature(id: 18, fx: 0.14, fy: 0.16, depth: 0.30, home: 9, kind: .glow(Color(hex: 0xD97757), 130)),
        Feature(id: 19, fx: 0.84, fy: 0.85, depth: 0.70, home: 9, kind: .planet(Color(hex: 0x4A90D9), 16)),
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

private struct OnboardingPage {
    enum Stage {
        case projects, workspace, docking, terminals, threads, servers, share,
             statusBar, reminders, themes
    }

    let stage: Stage
    let title: String
    let copy: String

    /// Copy is matter-of-fact (2026-09-27): what the thing is and what a
    /// click does, no pitch. The three workspace pages (chat/terminal
    /// surfaces, the side panel's docking, threads) are demos that play
    /// on their own and also answer clicks; a pulsing dot marks the next
    /// click, nothing else explains it.
    static let all: [OnboardingPage] = [
        OnboardingPage(
            stage: .projects,
            title: "Projects",
            copy: "Pin a project or a folder of them. The list is ordered by "
                + "what you opened most recently. Clicking a project opens its "
                + "workspace; if a chat there is mid-turn or waiting on you, it "
                + "opens on that chat."
        ),
        OnboardingPage(
            stage: .workspace,
            title: "Chat and Terminal",
            copy: "A project workspace is a top bar, a side panel, and one "
                + "surface: the chat or the terminal. Terminals in the bar "
                + "switches to the terminal. A chat in the panel switches back. "
                + "Both keep running."
        ),
        OnboardingPage(
            stage: .docking,
            title: "The Side Panel",
            copy: "Chats, terminals, branches, and servers each live in the side "
                + "panel or as a chip in the top bar. The dock control moves one "
                + "between the two. A window too narrow for the panel moves them "
                + "all to the bar."
        ),
        OnboardingPage(
            stage: .terminals,
            title: "Terminals",
            copy: "A terminal opens in the project's directory with your own "
                + "shell and dotfiles, on libghostty. Run claude, codex, or any "
                + "CLI in it. ⌘D splits a pane."
        ),
        OnboardingPage(
            stage: .threads,
            title: "Threads",
            copy: "Hover a paragraph of a reply and click the thread control. A "
                + "panel opens with that paragraph quoted; questions asked there "
                + "are answered there. The main conversation stays put."
        ),
        OnboardingPage(
            stage: .servers,
            title: "Servers",
            copy: "Dev servers running on your Mac are listed with their port "
                + "and health. A server row opens its page: open in the browser, "
                + "share, inspect, or stop."
        ),
        OnboardingPage(
            stage: .share,
            title: "Sharing",
            copy: "A running dev server is reachable from any device on your "
                + "Wi-Fi at project.local, with a QR code for phones. Public "
                + "links are part of Houston Live."
        ),
        OnboardingPage(
            stage: .statusBar,
            title: "The Status Bar",
            copy: "While a Claude session runs, the bar under the terminal shows "
                + "the model, context used, MCP health, and rate limits, read "
                + "from Claude's own statusline."
        ),
        OnboardingPage(
            stage: .reminders,
            title: "Reminders",
            copy: "Dated obligations like cert renewals and domain expiries, "
                + "tracked with the /track skill or by hand. The bell reminds "
                + "you before they are due."
        ),
        OnboardingPage(
            stage: .themes,
            title: "Themes",
            copy: "The terminal ships design-matched to Houston in light and "
                + "dark. About 500 ghostty themes are in the footer gear, "
                + "searchable, recents on top."
        ),
    ]
}

/// The illustration area: a fixed-size stage so every page's card is the
/// same height, each vignette drawn in Houston's own chrome.
private struct OnboardingStage: View {
    let kind: OnboardingPage.Stage

    var body: some View {
        Group {
            switch kind {
            case .projects: ProjectsVignette()
            case .workspace: WorkspaceVignette()
            case .docking: DockingVignette()
            case .terminals: TerminalVignette()
            case .threads: ThreadVignette()
            case .servers: ServersVignette()
            case .share: ShareVignette()
            case .statusBar: StatusBarVignette()
            case .reminders: RemindersVignette()
            case .themes: ThemesVignette()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .background(RoundedRectangle(cornerRadius: Theme.radiusFloat).fill(Theme.panelFill))
    }
}

// MARK: - Wordless "click here"

/// A pulsing dot over the control a demo wants clicked next: a solid dot
/// with two rings swelling out of it. Never intercepts the click.
private struct PulseHint: View {
    @State private var on = false

    var body: some View {
        ZStack {
            ring(delay: 0)
            ring(delay: 0.6)
            Circle()
                .fill(Theme.link)
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
        }
        .frame(width: 9, height: 9)
        .allowsHitTesting(false)
        .onAppear { on = true }
    }

    private func ring(delay: Double) -> some View {
        Circle()
            .stroke(Theme.link, lineWidth: 1.5)
            .scaleEffect(on ? 2.8 : 0.6)
            .opacity(on ? 0 : 0.9)
            .animation(
                .easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(delay),
                value: on
            )
    }
}

// MARK: - Workspace mini chrome

/// The vignettes' shared pieces: a mini workspace bar chip, the square
/// panel control, a module card — the app's own grammar at half scale.
private enum Mini {
    static let bar = Color(light: 0xFFFFFF, dark: 0x18181B)
    static let page = Color(light: 0xF4F4F5, dark: 0x0B0B0D)
    static let term = Color(light: 0xE0E0E0, dark: 0x181818)
    static let bubble = Color(light: 0x7E4340, dark: 0x8F5350)

    static func chip(
        _ icon: String, _ label: String, dot: Color? = nil, hint: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            LucideIcon(icon, size: 11)
                .foregroundStyle(Theme.textSecondary)
            if let dot {
                Circle().fill(dot).frame(width: 4, height: 4)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if hint { PulseHint().offset(x: 12) }
        }
    }

    static func control(_ icon: String, hint: Bool = false) -> some View {
        LucideIcon(icon, size: 10)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Theme.borderSidebar, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .overlay { if hint { PulseHint() } }
    }

    static func caps(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Theme.heading)
    }

    static func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(bar))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.borderSidebar, lineWidth: 1))
    }

    static func projectChip(_ name: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
            LucideIcon("chevron-down", size: 9)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 6)
    }

    /// The chat surface: one user bubble and a short reply.
    static func chatSurface(_ prompt: String, _ reply: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(prompt)
                .font(.system(size: 9.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(bubble))
            Text(reply)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The terminal surface: a prompt, a command, output, a cursor.
    static func terminalSurface() -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text("hierarch % ").foregroundStyle(Theme.textSecondary)
                Text("npm run dev").foregroundStyle(Theme.text)
            }
            Text("VITE v6.0.3  ready in 412 ms").foregroundStyle(Theme.textSecondary)
            Text("➜  Local:   http://localhost:5173/").foregroundStyle(Theme.textSecondary)
            HStack(spacing: 2) {
                Text("hierarch % ").foregroundStyle(Theme.textSecondary)
                Rectangle().fill(Theme.text.opacity(0.8)).frame(width: 6, height: 11)
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(term))
    }

    /// A module card's rows.
    static func chatRow(_ title: String, selected: Bool, hint: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Theme.rowSelected : .clear)
            )
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if hint { PulseHint().offset(x: 4) }
            }
    }

    static let chats = [
        "Align sidebar icons with projects",
        "Retry logic for the webhook worker",
        "Why the calendar re-renders",
    ]
}

/// One project workspace: bar on top, chat or terminal as the surface,
/// the CHATS card beside it. Plays on its own; clicks jump ahead.
private struct WorkspaceVignette: View {
    @State private var terminal = false
    @State private var chat = 0

    var body: some View {
        VStack(spacing: 8) {
            Mini.bar {
                Mini.projectChip("Hierarch")
                Mini.chip("git-branch", "main", dot: Theme.dotActive)
                Mini.chip("square-terminal", "Terminals", hint: !terminal)
                    .onTapGesture { withAnimation(Theme.quick) { terminal = true } }
            }
            HStack(spacing: 8) {
                Group {
                    if terminal {
                        Mini.terminalSurface()
                    } else {
                        Mini.chatSurface(
                            Mini.chats[chat],
                            "Moved the top rows onto the table's 6pt cell inset "
                                + "and matched the icon-to-label gap, so both columns "
                                + "share one left edge."
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Mini.caps("CHATS")
                        Spacer(minLength: 0)
                        Mini.control("plus")
                        Mini.control("panel-right-close")
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 7)
                    .padding(.bottom, 3)
                    ForEach(Mini.chats.indices, id: \.self) { index in
                        Mini.chatRow(
                            Mini.chats[index],
                            selected: !terminal && index == chat,
                            hint: terminal && index == 1
                        )
                        .onTapGesture {
                            withAnimation(Theme.quick) {
                                chat = index
                                terminal = false
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 3)
                .frame(width: 128)
                .background(RoundedRectangle(cornerRadius: 8).fill(Mini.bar))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderSidebar, lineWidth: 1))
            }
        }
        .padding(10)
        .frame(width: 400, height: 210)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Mini.page))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                withAnimation(Theme.quick) {
                    if terminal {
                        chat = 1
                        terminal = false
                    } else {
                        terminal = true
                    }
                }
            }
        }
    }
}

/// The side panel's items moving between the panel and the bar: the dock
/// control sends CHATS to the bar; its chip's dropdown brings it back.
private struct DockingVignette: View {
    @State private var docked = true
    @State private var dropdown = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 8) {
                Mini.bar {
                    Mini.projectChip("Hierarch")
                    Mini.chip("git-branch", "main", dot: Theme.dotActive)
                    Mini.chip("square-terminal", "Terminals")
                    if !docked {
                        Mini.chip("message-square-text", "Chats", hint: !dropdown)
                            .onTapGesture { withAnimation(Theme.quick) { dropdown = true } }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                HStack(spacing: 8) {
                    Mini.chatSurface(
                        Mini.chats[0],
                        "Moved the top rows onto the table's 6pt cell inset and "
                            + "matched the icon-to-label gap."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if docked {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Mini.caps("CHATS")
                                Spacer(minLength: 0)
                                Mini.control("plus")
                                Mini.control("panel-right-close", hint: true)
                                    .onTapGesture {
                                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { docked = false }
                                    }
                            }
                            .padding(.horizontal, 7)
                            .padding(.top, 7)
                            .padding(.bottom, 3)
                            ForEach(Mini.chats.indices, id: \.self) { index in
                                Mini.chatRow(Mini.chats[index], selected: index == 0)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 3)
                        .frame(width: 128)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Mini.bar))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderSidebar, lineWidth: 1))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .padding(10)

            // The bar chip's dropdown, straight down from the bar.
            if !docked && dropdown {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Mini.caps("CHATS")
                        Spacer(minLength: 0)
                        Mini.control("plus")
                        Mini.control("panel-right-open", hint: true)
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                                    dropdown = false
                                    docked = true
                                }
                            }
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 7)
                    .padding(.bottom, 3)
                    ForEach(Mini.chats.indices, id: \.self) { index in
                        Mini.chatRow(Mini.chats[index], selected: index == 0)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 5)
                .frame(width: 170)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.menuFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.borderSidebar, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .offset(x: 70, y: 46)
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .frame(width: 400, height: 210)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Mini.page))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                    if docked {
                        docked = false
                    } else if !dropdown {
                        dropdown = true
                    } else {
                        dropdown = false
                        docked = true
                    }
                }
            }
        }
    }
}

/// A reply's paragraphs, the thread control on one, and the thread panel
/// that opens with that paragraph quoted.
private struct ThreadVignette: View {
    @State private var open = false
    @State private var sent = false

    private let paragraphs = [
        "The booking card renders a skeleton while availability loads, matching the final layout so nothing shifts.",
        "Availability is fetched stale-while-revalidate: the cached range shows first and the refresh replaces it.",
        "A test renders the card with a pending promise and asserts the skeleton stays until it resolves.",
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 6) {
                        Text(paragraphs[index])
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.text)
                            .lineSpacing(2)
                            .opacity(open && index != 1 ? 0.5 : 1)
                        if index == 1 {
                            VStack(spacing: 3) {
                                Mini.control("reply", hint: !open)
                                    .onTapGesture {
                                        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { open = true }
                                    }
                                if sent {
                                    Text("1")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Theme.buttonFill))
                                        .transition(.opacity)
                                }
                            }
                        } else {
                            Color.clear.frame(width: 18, height: 18)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Mini.caps("THREAD")
                        Spacer(minLength: 0)
                        Mini.control("x", hint: sent)
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                                    open = false
                                    sent = false
                                }
                            }
                    }
                    Text("Availability is fetched stale-while-revalidate…")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .padding(.leading, 6)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Theme.link).frame(width: 2)
                        }
                    if sent {
                        Text("What happens if the refresh fails?")
                            .font(.system(size: 9))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Mini.bubble))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .transition(.opacity)
                        Text("The cached range stays on screen and the failure is logged.")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.text)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Text(sent ? "" : "What happens if the refresh fails?")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Circle()
                            .fill(sent ? Theme.buttonFill : Mini.bubble)
                            .frame(width: 16, height: 16)
                            .overlay(
                                LucideIcon("arrow-up", size: 9)
                                    .foregroundStyle(sent ? Theme.textSecondary : .white)
                            )
                            .overlay { if !sent { PulseHint() } }
                            .onTapGesture {
                                withAnimation(Theme.quick) { sent = true }
                            }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Mini.page))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderSidebar, lineWidth: 1))
                }
                .padding(8)
                .frame(width: 160)
                .frame(maxHeight: .infinity)
                .background(Mini.bar)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.borderSidebar).frame(width: 1)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 400, height: 210)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Mini.page))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSurface))
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.4))
                withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                    if !open {
                        open = true
                    } else if !sent {
                        sent = true
                    } else {
                        open = false
                        sent = false
                    }
                }
            }
        }
    }
}

/// A prompt typing `claude` out with a blinking block cursor.
private struct TerminalVignette: View {
    @State private var typed = 0
    @State private var cursorOn = true
    private let command = "claude"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Theme.closeRed).frame(width: 8, height: 8)
                Circle().fill(Color(hex: 0xD9A621)).frame(width: 8, height: 8)
                Circle().fill(Theme.dotActive).frame(width: 8, height: 8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Text("$ ")
                    .foregroundStyle(Theme.textSecondary)
                Text(String(command.prefix(typed)))
                    .foregroundStyle(Theme.text)
                Rectangle()
                    .fill(Theme.text.opacity(cursorOn ? 0.8 : 0))
                    .frame(width: 7, height: 15)
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            Spacer(minLength: 0)
        }
        .padding(16)
        // Top-leading, not the default center: a centered fixed frame
        // re-centers the natural-width content on every keystroke of the
        // typing animation, which visibly slid the traffic lights around.
        .frame(width: 340, height: 160, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSurface)
                .fill(Color(light: 0xE0E0E0, dark: 0x181818))
        )
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

/// Two detected server rows: health dot, address, open + kill controls.
private struct ServersVignette: View {
    var body: some View {
        VStack(spacing: 10) {
            row(name: "hierarch", url: "localhost:5173", dot: Theme.dotActive)
            row(name: "portfolio", url: "localhost:3000", dot: Theme.dotDegraded)
        }
    }

    private func row(name: String, url: String, dot: Color) -> some View {
        HStack(spacing: 9) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(name)
                .font(Theme.Fonts.bodyMedium)
                .foregroundStyle(Theme.text)
            Text(url)
                .font(Theme.Fonts.monoSmall)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            LucideIcon("arrow-up-right", size: 12)
                .foregroundStyle(Theme.textSecondary)
            LucideIcon("x", size: 11)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.rowHovered))
    }
}

/// The pretty `.local` link over its reach, with the public tier's badge.
private struct ShareVignette: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                LucideIcon("globe", size: 14)
                    .foregroundStyle(Theme.link)
                Text("hierarch.local")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.buttonFill))
            HStack(spacing: 6) {
                LucideIcon("wifi", size: 12)
                LucideIcon("smartphone", size: 13)
                Text("Any device on your Wi-Fi")
                    .font(Theme.Fonts.secondary)
            }
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                ComingSoonBadge()
                Text("Public live URLs")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// The sidebar's project list in miniature, add row included.
private struct ProjectsVignette: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROJECTS")
                .font(Theme.Fonts.label)
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
                .padding(.leading, 4)
                .padding(.bottom, 2)
            row(icon: "folder", name: "Apps")
            row(icon: "package", name: "hierarch", selected: true)
            row(icon: "package", name: "portfolio")
            row(icon: "plus", name: "Add", quiet: true)
        }
        .frame(width: 240)
    }

    private func row(
        icon: String, name: String, selected: Bool = false, quiet: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            LucideIcon(icon, size: 11)
                .foregroundStyle(Theme.textSecondary)
            Text(name)
                .font(Theme.Fonts.secondaryMedium)
                .foregroundStyle(quiet ? Theme.textSecondary : Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusControl)
                .fill(selected ? Theme.rowSelected : quiet ? .clear : Theme.rowHovered)
        )
    }
}

/// The status bar's items in miniature: model, context, MCP.
private struct StatusBarVignette: View {
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Opus 5")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                LucideIcon("chevron-down", size: 9)
                    .foregroundStyle(Theme.textSecondary)
            }
            divider
            HStack(spacing: 6) {
                ContextBar(pct: 0.38, color: Theme.Context.color(for: 0.38))
                Text("62% left")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
            divider
            HStack(spacing: 4) {
                Circle().fill(Theme.dotActive).frame(width: 5, height: 5)
                Text("MCP")
                    .font(Theme.Fonts.secondary)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.rowHovered))
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.borderSidebar)
            .frame(width: 1, height: 14)
    }
}

/// One tracked obligation with its countdown pill.
private struct RemindersVignette: View {
    var body: some View {
        HStack(spacing: 12) {
            LucideIcon("calendar", size: 16)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Renew TLS certificate")
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.text)
                Text("houston-relay · Nov 24")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Text("21d")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.dotDegraded))
        }
        .padding(14)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSurface).fill(Theme.rowHovered))
    }
}

/// A handful of theme swatches, the picker's tile style, one selected.
private struct ThemesVignette: View {
    private let swatches: [(bg: UInt32, fg: UInt32, picked: Bool)] = [
        (0xFDF6E3, 0x657B83, false),   // Solarized Light
        (0x282A36, 0xF8F8F2, true),    // Dracula
        (0x282828, 0xEBDBB2, false),   // Gruvbox
        (0x2E3440, 0xD8DEE9, false),   // Nord
        (0x191724, 0xE0DEF4, false),   // Rosé Pine
    ]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(swatches.indices, id: \.self) { index in
                let swatch = swatches[index]
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .fill(Color(hex: swatch.bg))
                    RoundedRectangle(cornerRadius: Theme.radiusSurface)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                    Text("A")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(hex: swatch.fg))
                }
                .frame(width: 46, height: 46)
                .overlay {
                    if swatch.picked {
                        RoundedRectangle(cornerRadius: Theme.radiusSurface)
                            .strokeBorder(Theme.link, lineWidth: 2)
                            .padding(-3.5)
                    }
                }
            }
        }
    }
}
