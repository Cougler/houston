import Foundation

/// What a project's own files say about how to start its dev server —
/// the off-server page's "default server" line.
enum DevCommandDetect {

    struct DefaultCommand: Equatable {
        /// The runnable launch command, e.g. "npm run dev".
        let command: String
        /// What the script actually does, e.g. "vite --port 3001".
        let script: String
        /// Vite ignores the PORT env var — a custom port must ride the
        /// script's own `--port` flag instead.
        let usesVite: Bool
    }

    /// package.json's dev-ish script through the package manager the
    /// lockfile names. nil when the project declares no server (or isn't a
    /// node project) — the page falls back to a blank command field.
    static func detect(projectPath: String) -> DefaultCommand? {
        let packageURL = URL(fileURLWithPath: projectPath)
            .appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return nil }
        guard let name = ["dev", "start", "serve"].first(where: { scripts[$0] != nil }),
              let script = scripts[name] else { return nil }

        let fm = FileManager.default
        func has(_ file: String) -> Bool {
            fm.fileExists(atPath: (projectPath as NSString).appendingPathComponent(file))
        }
        let manager =
            has("pnpm-lock.yaml") ? "pnpm"
            : has("yarn.lock") ? "yarn"
            : (has("bun.lockb") || has("bun.lock")) ? "bun"
            : "npm"
        // npm needs the `run` for non-lifecycle scripts; `npm start` is fine
        // bare but `npm run start` always works, so keep one form.
        let command = "\(manager) run \(name)"

        let deps = (json["dependencies"] as? [String: Any] ?? [:])
            .merging(json["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        let usesVite = deps["vite"] != nil || script.contains("vite")
        return DefaultCommand(command: command, script: script, usesVite: usesVite)
    }

    /// The command with the user's port applied — `--port` for vite (it
    /// ignores PORT), the PORT env var for everything else.
    static func apply(port: String, to command: String, usesVite: Bool) -> String {
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        guard !trimmedPort.isEmpty, Int(trimmedPort) != nil else { return command }
        return usesVite
            ? "\(command) -- --port \(trimmedPort)"
            : "PORT=\(trimmedPort) \(command)"
    }
}
