import SwiftUI

/// Houston's own consent dialog (2026-09-29), replacing the system alerts
/// for the status bar, notifications, and notifications-denied offers.
/// The system alert put a paragraph of settings.json mechanics in front of
/// a yes/no; this leads with what the user gets, keeps what changes on
/// disk to a one-line footnote, and draws in the app's own dialog grammar
/// (card fill, hairline, soft shadow, accent primary).
struct ConsentCard: View {
    let icon: String
    let title: String
    let message: String
    /// The fine print: what changes on disk and how to undo it. nil = none.
    var footnote: String? = nil
    let primary: String
    let secondary: String
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LucideIcon(icon, size: 18)
                .foregroundStyle(Theme.link)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.buttonActiveFill))

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if let footnote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    LucideIcon("file-cog", size: 12)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(footnote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary.opacity(0.9))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rowHovered))
                .padding(.top, 14)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onSecondary) {
                    Text(secondary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.buttonFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button(action: onPrimary) {
                    Text(primary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ctaFill))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
        }
        .padding(24)
        .frame(width: 400)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.menuFill)
                .shadow(color: Color.black.opacity(0.28), radius: 36, x: 0, y: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.borderSidebar, lineWidth: 1)
        )
    }
}

/// Presents at most one `ConsentCard` over the window on a dim scrim —
/// modal like the alert it replaced: the scrim swallows clicks, so the
/// user answers the card (or Esc) before going on.
struct ConsentLayer<Card: View>: View {
    let isPresented: Bool
    @ViewBuilder let card: () -> Card

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                card()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.1), value: isPresented)
    }
}
