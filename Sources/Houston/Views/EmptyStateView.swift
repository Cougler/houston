import AppKit
import SwiftUI

/// Shown when nothing is selected — most visibly right after the last shell
/// closes. The Houston helmet, faded into the background, plus the fastest
/// ways back to work.
struct EmptyStateView: View {
    /// Most recently touched projects, newest first.
    let recentProjects: [Project]
    let onOpen: (Project) -> Void

    /// The helmet from the app icon, baked as a white-on-alpha mask
    /// (`helmet@2x.png`) so it can be tinted like the tray template.
    private static let helmet: NSImage? = {
        guard let url = Bundle.module.url(
            forResource: "helmet@2x", withExtension: "png", subdirectory: "icons"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(spacing: 0) {
            if let helmet = Self.helmet {
                Image(nsImage: helmet)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                    .foregroundStyle(Theme.watermark)
            }

            Text("Mission control, standing by")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 24)

            Text("Pick a project from the sidebar to open a shell in it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)

            if !recentProjects.isEmpty {
                Text("JUMP BACK IN")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(Theme.heading)
                    .padding(.top, 28)

                HStack(spacing: 8) {
                    ForEach(recentProjects) { project in
                        Button {
                            onOpen(project)
                        } label: {
                            Text(project.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                        .modifier(HeaderButtonChrome())
                    }
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
