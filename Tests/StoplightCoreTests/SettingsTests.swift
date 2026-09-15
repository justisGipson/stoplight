import Testing
import Foundation
@testable import StoplightCore

private func scratchDefaults() -> UserDefaults {
    let suite = "stoplight-tests-\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test @MainActor func settingsDefaultToSystemAndMedium() {
    let settings = Settings(defaults: scratchDefaults())
    #expect(settings.appearance == .system)
    #expect(settings.fontScale == .medium)
}

@Test @MainActor func settingsSurviveARelaunch() {
    let defaults = scratchDefaults()
    let first = Settings(defaults: defaults)
    first.appearance = .dark
    first.fontScale = .large

    let second = Settings(defaults: defaults)
    #expect(second.appearance == .dark)
    #expect(second.fontScale == .large)
}

@Test @MainActor func unrecognisedStoredValuesFallBackToDefaults() {
    let defaults = scratchDefaults()
    defaults.set("chartreuse", forKey: "appearance")
    defaults.set("enormous", forKey: "fontScale")
    let settings = Settings(defaults: defaults)
    #expect(settings.appearance == .system)
    #expect(settings.fontScale == .medium)
}

@Test func systemAppearanceInheritsRatherThanForcing() {
    // nil is what lets the window follow the system.
    #expect(AppearanceMode.system.nsAppearance == nil)
    #expect(AppearanceMode.dark.nsAppearance != nil)
}

@Test func fontScaleFactorsAreOrdered() {
    let factors = FontScale.allCases.map(\.factor)
    #expect(factors == factors.sorted())
    #expect(FontScale.medium.factor == 1.0)
}

// MARK: - Provider

private func settingsFile(_ contents: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "stoplight-cfg-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "settings.json")
    try Data(contents.utf8).write(to: url)
    return url
}

@Test func claudeIsTheProviderWhenNoFlagsAreSet() throws {
    let url = try settingsFile(#"{"model":"opus"}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(ClaudeSettingsFile.provider(in: url) == .anthropic)
}

@Test func bedrockIsDetectedFromItsFlag() throws {
    let url = try settingsFile(#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(ClaudeSettingsFile.provider(in: url) == .bedrock)
}

@Test func switchingProviderLeavesEverythingElseUntouched() throws {
    // This file carries the user's hooks and permissions. Only the two provider
    // keys may move.
    let url = try settingsFile("""
    {"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash"}]},
     "permissions":{"allow":["Bash"]},"env":{"FOO":"bar"}}
    """)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(ClaudeSettingsFile.setProvider(.bedrock, in: url) != .unchanged)

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect(json["model"] as? String == "opus")
    #expect(json["hooks"] != nil)
    #expect(json["permissions"] != nil)
    let env = json["env"] as! [String: Any]
    #expect(env["FOO"] as? String == "bar")
    #expect(env["CLAUDE_CODE_USE_BEDROCK"] as? String == "1")
}

@Test func switchingBackToClaudeRemovesTheFlagEntirely() throws {
    // Claude is the default, and the default is the absence of both flags rather
    // than a flag set to zero.
    let url = try settingsFile(#"{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","FOO":"bar"}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    ClaudeSettingsFile.setProvider(.anthropic, in: url)

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let env = json["env"] as! [String: Any]
    #expect(env["CLAUDE_CODE_USE_BEDROCK"] == nil)
    #expect(env["FOO"] as? String == "bar")
    #expect(ClaudeSettingsFile.provider(in: url) == .anthropic)
}

@Test func switchingProviderBacksUpFirst() throws {
    let url = try settingsFile(#"{"env":{"FOO":"bar"}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(ClaudeSettingsFile.setProvider(.vertex, in: url) == .written(backup: "settings.json.stoplight-backup"))
    let backup = url.deletingLastPathComponent().appending(path: "settings.json.stoplight-backup")
    #expect(FileManager.default.fileExists(atPath: backup.path))
}

@Test func reselectingTheCurrentProviderWritesNothing() throws {
    let url = try settingsFile(#"{"env":{"FOO":"bar"}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(ClaudeSettingsFile.setProvider(.anthropic, in: url) == .unchanged)
}

@Test func anEmptyEnvIsRemovedRatherThanLeftBehind() throws {
    let url = try settingsFile(#"{"env":{"CLAUDE_CODE_USE_VERTEX":"1"}}"#)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    ClaudeSettingsFile.setProvider(.anthropic, in: url)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect(json["env"] == nil)
}

@Test func anUnreadableSettingsFileFailsWithoutThrowing() {
    let result = ClaudeSettingsFile.setProvider(.bedrock, in: URL(fileURLWithPath: "/nowhere.json"))
    guard case .failed = result else { Issue.record("expected failure"); return }
}

// MARK: - Focus

@Test func theCurrentProcessHasAParent() {
    #expect(SessionFocus.parentPid(of: getpid()) != nil)
}

@Test func anImpossiblePidHasNoParent() {
    #expect(SessionFocus.parentPid(of: pid_t(Int32.max)) == nil)
}

@Test @MainActor func aProcessWithNoGuiAncestorResolvesToNothing() {
    // launchd is pid 1 and owns no application.
    #expect(SessionFocus.owningApplication(of: 1) == nil)
}
