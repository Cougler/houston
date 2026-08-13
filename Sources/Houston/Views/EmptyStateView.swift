import AppKit
import SwiftUI

/// Shown when nothing is selected — most visibly right after the last shell
/// closes. A slow solar system turns in the center of the pane under a field
/// of twinkling stars and the occasional shooting star.
struct EmptyStateView: View {
    /// Drives the entrance; reset on every appearance because the view is
    /// rebuilt each time the selection empties.
    @State private var appeared = false

    /// The star field, positioned as fractions of the pane so it fills any
    /// window size. Mostly neutral, with one warm and one cool accent.
    private struct StarSpec: Identifiable {
        let id: Int
        let fx: CGFloat
        let fy: CGFloat
        let size: CGFloat
        let color: Color
        let duration: Double
        let delay: Double
    }

    private static let stars: [StarSpec] = [
        StarSpec(id: 0, fx: 0.50, fy: 0.08, size: 2.0, color: Theme.heading, duration: 2.6, delay: 0.2),
        StarSpec(id: 1, fx: 0.62, fy: 0.11, size: 2.0, color: Theme.heading, duration: 2.2, delay: 0.0),
        StarSpec(id: 2, fx: 0.71, fy: 0.15, size: 1.8, color: Theme.heading, duration: 3.0, delay: 1.1),
        StarSpec(id: 3, fx: 0.36, fy: 0.18, size: 2.0, color: Color(hex: 0xD97757), duration: 3.2, delay: 0.7),
        StarSpec(id: 4, fx: 0.25, fy: 0.10, size: 1.6, color: Theme.heading, duration: 2.9, delay: 1.6),
        StarSpec(id: 5, fx: 0.85, fy: 0.09, size: 1.8, color: Theme.heading, duration: 2.4, delay: 0.5),
        StarSpec(id: 6, fx: 0.12, fy: 0.22, size: 1.6, color: Theme.heading, duration: 3.4, delay: 0.9),
        StarSpec(id: 7, fx: 0.08, fy: 0.78, size: 1.8, color: Theme.heading, duration: 2.0, delay: 0.4),
        StarSpec(id: 8, fx: 0.91, fy: 0.72, size: 1.6, color: Theme.heading, duration: 3.1, delay: 1.3),
        StarSpec(id: 9, fx: 0.20, fy: 0.55, size: 1.6, color: Theme.heading, duration: 2.7, delay: 0.8),
        StarSpec(id: 10, fx: 0.13, fy: 0.38, size: 2.0, color: Theme.heading, duration: 3.3, delay: 0.3),
        StarSpec(id: 11, fx: 0.86, fy: 0.45, size: 2.0, color: Color(hex: 0x3B82F6), duration: 2.5, delay: 1.0),
        StarSpec(id: 12, fx: 0.93, fy: 0.25, size: 1.5, color: Theme.heading, duration: 3.6, delay: 1.8),
        StarSpec(id: 13, fx: 0.06, fy: 0.60, size: 1.5, color: Theme.heading, duration: 2.8, delay: 1.5),
        StarSpec(id: 14, fx: 0.42, fy: 0.90, size: 1.5, color: Theme.heading, duration: 3.0, delay: 2.0),
        StarSpec(id: 15, fx: 0.79, fy: 0.88, size: 1.5, color: Theme.heading, duration: 2.3, delay: 2.3),
        StarSpec(id: 16, fx: 0.05, fy: 0.06, size: 1.6, color: Theme.heading, duration: 2.7, delay: 1.2),
        StarSpec(id: 17, fx: 0.15, fy: 0.14, size: 1.3, color: Theme.heading, duration: 3.5, delay: 0.1),
        StarSpec(id: 18, fx: 0.31, fy: 0.07, size: 1.4, color: Theme.heading, duration: 2.1, delay: 1.9),
        StarSpec(id: 19, fx: 0.44, fy: 0.14, size: 1.3, color: Theme.heading, duration: 3.2, delay: 0.6),
        StarSpec(id: 20, fx: 0.57, fy: 0.20, size: 1.5, color: Theme.heading, duration: 2.4, delay: 2.6),
        StarSpec(id: 21, fx: 0.68, fy: 0.05, size: 1.7, color: Theme.heading, duration: 2.9, delay: 0.9),
        StarSpec(id: 22, fx: 0.78, fy: 0.17, size: 1.3, color: Theme.heading, duration: 3.7, delay: 1.4),
        StarSpec(id: 23, fx: 0.95, fy: 0.12, size: 1.8, color: Theme.heading, duration: 2.2, delay: 2.1),
        StarSpec(id: 24, fx: 0.96, fy: 0.55, size: 1.4, color: Theme.heading, duration: 3.1, delay: 0.4),
        StarSpec(id: 25, fx: 0.90, fy: 0.83, size: 1.6, color: Theme.heading, duration: 2.6, delay: 1.7),
        StarSpec(id: 26, fx: 0.66, fy: 0.93, size: 1.3, color: Theme.heading, duration: 3.4, delay: 0.2),
        StarSpec(id: 27, fx: 0.52, fy: 0.82, size: 1.4, color: Color(hex: 0xD9C27E), duration: 2.8, delay: 2.4),
        StarSpec(id: 28, fx: 0.28, fy: 0.86, size: 1.6, color: Theme.heading, duration: 2.0, delay: 1.1),
        StarSpec(id: 29, fx: 0.10, fy: 0.92, size: 1.3, color: Theme.heading, duration: 3.6, delay: 0.7),
        StarSpec(id: 30, fx: 0.04, fy: 0.30, size: 1.5, color: Theme.heading, duration: 2.5, delay: 2.8),
        StarSpec(id: 31, fx: 0.18, fy: 0.70, size: 1.3, color: Theme.heading, duration: 3.0, delay: 1.6),
        StarSpec(id: 32, fx: 0.33, fy: 0.32, size: 1.2, color: Theme.heading, duration: 2.9, delay: 0.5),
        StarSpec(id: 33, fx: 0.67, fy: 0.35, size: 1.2, color: Theme.heading, duration: 3.3, delay: 2.2),
        StarSpec(id: 34, fx: 0.61, fy: 0.65, size: 1.2, color: Theme.heading, duration: 2.3, delay: 1.0),
        StarSpec(id: 35, fx: 0.38, fy: 0.68, size: 1.2, color: Theme.heading, duration: 3.8, delay: 0.3),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.stars) { star in
                    TwinkleStar(
                        size: star.size,
                        color: star.color,
                        duration: star.duration,
                        delay: star.delay
                    )
                    .position(x: geo.size.width * star.fx, y: geo.size.height * star.fy)
                }

                Comet()
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.5)

                SolarSystem()
                    .reveal(appeared, delay: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // What to do next, quietly under the animation.
                VStack(spacing: 6) {
                    Text("Houston is standing by")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Pick a project in the sidebar and start a mission or open a new terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 48)
                .reveal(appeared, delay: 0.4)
            }
        }
        .background(Theme.emptyStateBackground)
        .clipped()
        .onAppear {
            // Next runloop tick so the first frame renders hidden and the
            // change actually animates.
            DispatchQueue.main.async { appeared = true }
        }
    }
}

// MARK: - Solar system

/// Our solar system, politely compressed: the sun, eight planets on faint
/// orbit rings, each turning at its own (slow) period so the arrangement
/// never repeats. Sizes and spacing are legibility-first, not to scale —
/// a true-scale drawing is mostly empty space and four invisible dots.
struct SolarSystem: View {

    struct Planet: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let size: CGFloat
        let orbit: CGFloat
        /// Seconds per revolution.
        let period: Double
        /// Fixed scatter so the planets don't start in a line.
        let startAngle: Double
        var hasRing = false
    }

    static let planets: [Planet] = [
        Planet(name: "Mercury", color: Color(hex: 0x9CA3AF), size: 3, orbit: 44, period: 26, startAngle: 40),
        Planet(name: "Venus", color: Color(hex: 0xE0C084), size: 4.5, orbit: 62, period: 42, startAngle: 190),
        Planet(name: "Earth", color: Color(hex: 0x4A90D9), size: 5, orbit: 80, period: 60, startAngle: 305),
        Planet(name: "Mars", color: Color(hex: 0xD9603B), size: 4, orbit: 98, period: 84, startAngle: 120),
        Planet(name: "Jupiter", color: Color(hex: 0xC98F4C), size: 10, orbit: 126, period: 130, startAngle: 250),
        Planet(name: "Saturn", color: Color(hex: 0xD9C27E), size: 8.5, orbit: 154, period: 180, startAngle: 15, hasRing: true),
        Planet(name: "Uranus", color: Color(hex: 0x8FD3D9), size: 6.5, orbit: 180, period: 240, startAngle: 150),
        Planet(name: "Neptune", color: Color(hex: 0x5069D9), size: 6, orbit: 205, period: 300, startAngle: 80),
    ]

    var body: some View {
        ZStack {
            // Orbit rings.
            ForEach(Self.planets) { planet in
                Circle()
                    .stroke(Theme.orbitRing, lineWidth: 1)
                    .frame(width: planet.orbit * 2, height: planet.orbit * 2)
            }

            // The sun: warm core with a soft halo.
            Circle()
                .fill(Color(hex: 0xE8A33D).opacity(0.35))
                .frame(width: 44, height: 44)
                .blur(radius: 10)
            Circle()
                .fill(RadialGradient(
                    colors: [Color(hex: 0xFFD98A), Color(hex: 0xE8A33D)],
                    center: .center,
                    startRadius: 0,
                    endRadius: 13
                ))
                .frame(width: 26, height: 26)

            ForEach(Self.planets) { planet in
                OrbitingPlanet(planet: planet)
            }
        }
        .frame(width: 430, height: 430)
    }
}

/// One planet riding its orbit: the offset-then-rotate trick swings the body
/// around the system's center; linear and forever, at the planet's period.
private struct OrbitingPlanet: View {
    let planet: SolarSystem.Planet
    @State private var angle: Double = 0

    var body: some View {
        planetBody
            .offset(x: planet.orbit)
            .rotationEffect(.degrees(planet.startAngle + angle))
            .onAppear {
                DispatchQueue.main.async {
                    withAnimation(.linear(duration: planet.period).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                }
            }
    }

    private var planetBody: some View {
        Circle()
            .fill(planet.color)
            .frame(width: planet.size, height: planet.size)
            .overlay {
                if planet.hasRing {
                    Ellipse()
                        .stroke(planet.color.opacity(0.55), lineWidth: 1)
                        .frame(width: planet.size * 2.1, height: planet.size * 0.8)
                        .rotationEffect(.degrees(-18))
                }
            }
            .help(planet.name)
    }
}

// MARK: - Stars

/// A dot that softly brightens and dims on its own rhythm.
private struct TwinkleStar: View {
    let size: CGFloat
    let color: Color
    let duration: Double
    let delay: Double

    @State private var bright = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(bright ? 0.75 : 0.12)
            .scaleEffect(bright ? 1 : 0.7)
            .onAppear {
                DispatchQueue.main.async {
                    withAnimation(
                        .easeInOut(duration: duration)
                            .repeatForever(autoreverses: true)
                            .delay(delay)
                    ) {
                        bright = true
                    }
                }
            }
    }
}

/// A comet that passes through the system every so often: long quiet gaps,
/// then a ~3-second crossing — icy head, glowing coma, fading tail — on a
/// different trajectory (side, height, slope) each time.
private struct Comet: View {
    @State private var progress: CGFloat = 0
    @State private var visible = false
    @State private var startX: CGFloat = -420
    @State private var baseY: CGFloat = -60
    @State private var drop: CGFloat = 90

    private var endX: CGFloat { -startX }

    var body: some View {
        ZStack {
            // Tail fades away behind the head (which rides at +x).
            Capsule()
                .fill(LinearGradient(
                    colors: [.clear, Color(hex: 0x8FD3D9).opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: 72, height: 2)
            // Coma glow, then the icy nucleus.
            Circle()
                .fill(Color(hex: 0x8FD3D9).opacity(0.55))
                .frame(width: 8, height: 8)
                .blur(radius: 4)
                .offset(x: 36)
            Circle()
                .fill(Color(hex: 0xD9EEF5))
                .frame(width: 3.5, height: 3.5)
                .offset(x: 36)
        }
        // Rotation aims local +x along the travel direction, so the head
        // leads and the tail trails whichever way the comet flies.
        .rotationEffect(.radians(Double(atan2(drop, endX - startX))))
        .opacity(visible ? 1 : 0)
        .offset(
            x: startX + (endX - startX) * progress,
            y: baseY + drop * progress
        )
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 12...24)))
                guard !Task.isCancelled else { return }
                startX = Bool.random() ? -420 : 420
                baseY = CGFloat.random(in: -160...80)
                drop = CGFloat.random(in: -50...150)
                withAnimation(.easeIn(duration: 0.25)) { visible = true }
                withAnimation(.linear(duration: 3.0)) { progress = 1 }
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(.easeOut(duration: 0.35)) { visible = false }
                try? await Task.sleep(for: .seconds(0.4))
                progress = 0
            }
        }
    }
}

// MARK: - Entrance

/// Entrance treatment: fade in while sliding up, on a soft spring, `delay`
/// seconds into the stagger.
private struct Reveal: ViewModifier {
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
    fileprivate func reveal(_ on: Bool, delay: Double) -> some View {
        modifier(Reveal(on: on, delay: delay))
    }
}
