import Foundation

/// Where Claude Code sends its requests. Claude is the model throughout — the
/// provider is who serves it.
public enum ClaudeProvider: String, CaseIterable, Sendable {
    case anthropic, bedrock, vertex

    public var label: String {
        switch self {
        case .anthropic: "Claude (default)"
        case .bedrock: "AWS Bedrock"
        case .vertex: "Google Vertex"
        }
    }

    public var note: String {
        switch self {
        case .anthropic: "Anthropic's API, using your existing Claude subscription."
        case .bedrock: "Requires AWS credentials and a region in your environment."
        case .vertex: "Requires Google Cloud credentials and a region in your environment."
        }
    }

    static let bedrockKey = "CLAUDE_CODE_USE_BEDROCK"
    static let vertexKey = "CLAUDE_CODE_USE_VERTEX"
}

/// Reads and writes the provider flags in `~/.claude/settings.json`.
///
/// This is the one place Stoplight writes to your Claude Code config, so it is
/// deliberately narrow: it touches exactly two keys inside `env`, leaves every
/// other setting — hooks, permissions, model, plugins — byte-for-byte alone, and
/// backs the file up before each write.
///
/// The flags are read when a session starts, so a change takes effect for **new**
/// sessions. Nothing already running is affected.
public enum ClaudeSettingsFile {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    public static func provider(in url: URL = ClaudeSettingsFile.defaultURL) -> ClaudeProvider {
        let env = readEnv(in: url)
        if isOn(env[ClaudeProvider.bedrockKey]) { return .bedrock }
        if isOn(env[ClaudeProvider.vertexKey]) { return .vertex }
        return .anthropic
    }

    static func isOn(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let text = value as? String { return text == "1" || text.lowercased() == "true" }
        if let number = value as? Int { return number == 1 }
        return false
    }

    static func readEnv(in url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return json["env"] as? [String: Any] ?? [:]
    }

    public enum WriteResult: Equatable {
        case unchanged
        case written(backup: String)
        case failed(String)
    }

    @discardableResult
    public static func setProvider(_ provider: ClaudeProvider,
                                   in url: URL = ClaudeSettingsFile.defaultURL) -> WriteResult {
        guard let data = try? Data(contentsOf: url),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .failed("could not read \(url.lastPathComponent)") }

        var env = json["env"] as? [String: Any] ?? [:]
        let before = env

        env.removeValue(forKey: ClaudeProvider.bedrockKey)
        env.removeValue(forKey: ClaudeProvider.vertexKey)
        switch provider {
        case .anthropic: break   // the default is the absence of both flags
        case .bedrock: env[ClaudeProvider.bedrockKey] = "1"
        case .vertex: env[ClaudeProvider.vertexKey] = "1"
        }

        guard !NSDictionary(dictionary: env).isEqual(to: before) else { return .unchanged }

        if env.isEmpty { json.removeValue(forKey: "env") } else { json["env"] = env }

        // Back up first. This file carries the user's hooks and permissions.
        let backup = url.deletingLastPathComponent()
            .appending(path: "settings.json.stoplight-backup")
        try? data.write(to: backup, options: .atomic)

        guard let encoded = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? encoded.write(to: url, options: .atomic)) != nil
        else { return .failed("could not write \(url.lastPathComponent)") }

        return .written(backup: backup.lastPathComponent)
    }
}
