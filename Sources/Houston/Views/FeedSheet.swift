import SwiftUI

/// The Notifications sheet: flat on the sheet's background, one card per
/// event — kind glyph in a tinted circle, headline and age, then the
/// message. Clicking a card jumps to its project when it has one.
struct FeedSheet: View {
    @ObservedObject var feed: EventFeed
    let onOpen: (HoustonEvent) -> Void

    var body: some View {
        if feed.events.isEmpty {
            emptyState
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer(minLength: 0)
                        QuietTextButton(title: "Clear All") {
                            withAnimation(.easeOut(duration: 0.15)) {
                                feed.clear()
                            }
                        }
                    }
                    ForEach(feed.events) { event in
                        FeedEventCard(event: event) { onOpen(event) }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bell")
                .font(.system(size: 20))
                .foregroundStyle(Theme.heading)
            Text("You\u{2019}re all caught up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Sessions needing you, tracked reminders, and commits "
                + "show up here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeedEventCard: View {
    let event: HoustonEvent
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: glyph)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(glyphColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(EventFeed.age(of: event))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textPath)
                }
                Text(event.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.buttonFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.buttonStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
    }

    private var glyph: String {
        switch event.kind {
        case .needsInput: "exclamationmark.bubble"
        case .finished: "checkmark.bubble"
        case .trackedDue: "calendar"
        case .commit: "arrow.triangle.branch"
        }
    }

    private var glyphColor: Color {
        switch event.kind {
        case .needsInput: Theme.dotDegraded
        case .finished: Theme.dotActive
        case .trackedDue: Theme.dotDegraded
        case .commit: Theme.textSecondary
        }
    }
}

/// A small, quiet inline text action.
private struct QuietTextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hovered ? Theme.text : Theme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
