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
                    .foregroundStyle(Theme.text)
                Text("Mission control for your coding agents.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
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
                    .foregroundStyle(Theme.text)
                    .padding(.top, 30)
                Text(shown.copy)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
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

    /// Active page: a wide capsule in the text color so it reads on the sky
    /// in both appearances.
    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == page ? Theme.text : Theme.heading.opacity(0.35))
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
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
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
        case terminals, servers, share, projects, statusBar, reminders, themes
    }

    let stage: Stage
    let title: String
    let copy: String

    static let all: [OnboardingPage] = [
        OnboardingPage(
            stage: .terminals,
            title: "Terminals",
            copy: "Real terminals, right inside Houston. Click a project to open "
                + "a shell in its directory, run Claude Code or any other coding "
                + "agent, and split panes with ⌘D."
        ),
        OnboardingPage(
            stage: .servers,
            title: "Servers",
            copy: "Dev servers running on your Mac appear automatically. Check "
                + "their health at a glance, open one in the browser, or kill a "
                + "stray process. No hunting for pids."
        ),
        OnboardingPage(
            stage: .share,
            title: "Share Your Work",
            copy: "Reach a running dev server from any device on your Wi-Fi at "
                + "project.local. Public live URLs that anyone can open from "
                + "anywhere are coming soon."
        ),
        OnboardingPage(
            stage: .projects,
            title: "Projects",
            copy: "Add a single project or a whole folder of them. Clicking a "
                + "project starts a terminal already sitting in the right "
                + "directory."
        ),
        OnboardingPage(
            stage: .statusBar,
            title: "The Status Bar",
            copy: "While a Claude session runs, the bar under the terminal shows "
                + "the model, context remaining, MCP health, and your rate "
                + "limits, live from Claude's own statusline."
        ),
        OnboardingPage(
            stage: .reminders,
            title: "Reminders",
            copy: "Track dated obligations like cert renewals, domain expiries, "
                + "and secret rotations with the /track skill or by hand. "
                + "Houston reminds you before they're due."
        ),
        OnboardingPage(
            stage: .themes,
            title: "Make It Yours",
            copy: "The terminal ships design-matched to Houston in light and "
                + "dark. Or pick from ~500 ghostty themes in the footer gear, "
                + "searchable with your recents on top."
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
            case .terminals: TerminalVignette()
            case .servers: ServersVignette()
            case .share: ShareVignette()
            case .projects: ProjectsVignette()
            case .statusBar: StatusBarVignette()
            case .reminders: RemindersVignette()
            case .themes: ThemesVignette()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 250)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panelFill))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
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
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(light: 0xE0E0E0, dark: 0x181818))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowHovered))
    }
}

/// The pretty `.local` link over its reach, with the public tier's badge.
private struct ShareVignette: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.link)
                Text("hierarch.local")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.buttonFill))
            .overlay(Capsule().strokeBorder(Theme.buttonStroke, lineWidth: 1))
            HStack(spacing: 6) {
                Image(systemName: "wifi")
                    .font(.system(size: 10))
                Image(systemName: "iphone")
                    .font(.system(size: 11))
                Text("Any device on your Wi-Fi")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                ComingSoonBadge()
                Text("Public live URLs")
                    .font(.system(size: 11))
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
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
                .padding(.leading, 4)
                .padding(.bottom, 2)
            row(icon: "folder", name: "Apps")
            row(icon: "shippingbox", name: "hierarch", selected: true)
            row(icon: "shippingbox", name: "portfolio")
            row(icon: "plus", name: "Add", quiet: true)
        }
        .frame(width: 240)
    }

    private func row(
        icon: String, name: String, selected: Bool = false, quiet: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textSecondary)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(quiet ? Theme.textSecondary : Theme.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            divider
            HStack(spacing: 6) {
                ContextBar(pct: 0.38, color: Theme.Context.color(for: 0.38))
                Text("62% left")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            divider
            HStack(spacing: 4) {
                Circle().fill(Theme.dotActive).frame(width: 5, height: 5)
                Text("MCP")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.rowHovered))
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
            Image(systemName: "calendar")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Renew TLS certificate")
                    .font(.system(size: 12, weight: .medium))
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.rowHovered))
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
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: swatch.bg))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.borderSidebar, lineWidth: 1)
                    Text("A")
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(hex: swatch.fg))
                }
                .frame(width: 46, height: 46)
                .overlay {
                    if swatch.picked {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Theme.link, lineWidth: 2)
                            .padding(-3.5)
                    }
                }
            }
        }
    }
}
