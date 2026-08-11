import SwiftUI

/// Status and actions for a running dev server, shown in the right pane when a
/// server row is selected. Selecting a server never touches a shell.
struct ServerDetailView: View {
    let server: DevServer
    let onOpenTerminal: () -> Void

    @State private var confirmingStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                details
                Divider()
                actions
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.blue)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.project ?? server.command)
                    .font(.system(size: 20, weight: .semibold))
                Text("Listening on port " + String(server.port))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailRow(label: "URL") {
                Button(server.url) { Actions.openExternal(server.url) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            DetailRow(label: "Port") {
                Text(String(server.port)).font(.system(size: 12, design: .monospaced))
            }
            DetailRow(label: "PID") {
                Text(String(server.pid)).font(.system(size: 12, design: .monospaced))
            }
            DetailRow(label: "Command") {
                Text(server.command)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let cwd = server.cwd {
                DetailRow(label: "Directory") {
                    Text(cwd)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Actions.openExternal(server.url)
            } label: {
                Label("Open in Browser", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)

            if server.cwd != nil {
                Button(action: onOpenTerminal) {
                    Label("Open Terminal Here", systemImage: "terminal")
                }
            }

            Spacer()

            Button(role: .destructive) {
                confirmingStop = true
            } label: {
                Label("Stop Server", systemImage: "stop.fill")
            }
            // Stopping is a real kill of someone's dev server, and the row is
            // one click away from the terminal rows — worth a confirm.
            .confirmationDialog(
                "Stop \(server.project ?? server.command)?",
                isPresented: $confirmingStop,
                titleVisibility: .visible
            ) {
                Button("Stop Server", role: .destructive) {
                    Actions.killPid(server.pid)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sends SIGTERM to pid \(String(server.pid)) on port \(String(server.port)).")
            }
        }
    }
}

private struct DetailRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}
