import Foundation
import Security

enum AIProviderError: Error, Equatable, Sendable {
    case notInstalled
    case unverified
    case signInNeeded
    case timedOut
    case cancelled
    case busy
    case failed
    case invalidResponse
}

enum AIProviderStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case unverified
    case signInNeeded(version: String?)
    case ready(version: String?)

    /// Installed and signed by its vendor; it may still need a sign-in.
    var isInstalled: Bool {
        switch self {
        case .signInNeeded, .ready: return true
        case .checking, .notInstalled, .unverified: return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

protocol BriefProviding: Sendable {
    var kind: AIProviderKind { get }
    func status() async -> AIProviderStatus
    func run(_ call: AIBriefCall) async throws -> AIBriefResult
}

// MARK: - Locating and verifying a vendor-signed CLI

enum SignedCLILocation: Equatable, Sendable {
    case notFound
    case unverified(URL)
    case verified(URL)
}

/// Finds the first installed candidate and accepts it only when its code
/// signature satisfies the vendor's designated requirement. The user-local
/// install folders are writable by the account, so a path alone proves nothing.
struct SignedCLILocator: Sendable {
    let candidates: [URL]
    let requirement: String
    private let validate: @Sendable (URL, String) -> Bool

    init(
        candidates: [URL],
        requirement: String,
        validate: @escaping @Sendable (URL, String) -> Bool = { url, requirement in
            CodeSignatureCheck.satisfies(url, requirement: requirement)
        }
    ) {
        self.candidates = candidates
        self.requirement = requirement
        self.validate = validate
    }

    /// The first candidate that resolves to an executable regular file.
    func firstInstalledCandidate() -> URL? {
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: resolved.path),
               (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return resolved
            }
        }
        return nil
    }

    func isVerified(_ url: URL) -> Bool {
        validate(url, requirement)
    }
}

enum CodeSignatureCheck {
    /// Full static validation (all architectures, strict) against a designated
    /// requirement. Hashes the whole binary, so callers should not loop on it.
    static func satisfies(_ url: URL, requirement text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }
}

/// Caches a verified signature per file identity, so the 50 MB+ Claude Code
/// binary is hashed once per install, while any replacement is re-verified.
actor SignatureCache {
    private struct FileIdentity: Hashable {
        let path: String
        let size: Int
        let modified: Date
        let inode: Int
    }

    private var verified: Set<FileIdentity> = []

    func location(for locator: SignedCLILocator) -> SignedCLILocation {
        guard let resolved = locator.firstInstalledCandidate() else { return .notFound }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: resolved.path)) ?? [:]
        let identity = FileIdentity(
            path: resolved.path,
            size: (attributes[.size] as? Int) ?? -1,
            modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
            inode: (attributes[.systemFileNumber] as? Int) ?? -1
        )
        if verified.contains(identity) { return .verified(resolved) }
        guard locator.isVerified(resolved) else { return .unverified(resolved) }
        verified.insert(identity)
        return .verified(resolved)
    }
}

private func makePrivateTemporaryDirectory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func mapRunnerError(_ error: Error) -> AIProviderError {
    if error is CancellationError { return .cancelled }
    switch error as? BoundedProcessError {
    case .cancelled?: return .cancelled
    case .timedOut?: return .timedOut
    case .outputTooLarge?, .inputTooLarge?: return .invalidResponse
    case .launchFailed?, nil: return .failed
    }
}

private func isAuthenticationFailure(_ stderr: Data) -> Bool {
    guard let message = String(data: stderr, encoding: .utf8)?.lowercased() else { return false }
    return [
        "not logged in",
        "login required",
        "authentication required",
        "unauthorized",
        "please run codex login",
        "sign in"
    ].contains(where: message.contains)
}

private func baseEnvironment(from source: [String: String]) -> [String: String] {
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NO_COLOR": "1"]
    for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE"] {
        if let value = source[key], !value.isEmpty { environment[key] = value }
    }
    environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
    // The CLIs find the user's login (Keychain item) by account name.
    environment["USER"] = environment["USER"] ?? NSUserName()
    environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
    return environment
}

// MARK: - Claude Code

actor ClaudeCodeProvider: BriefProviding {
    nonisolated let kind = AIProviderKind.claude

    static let designatedRequirement = #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "Q6L2SF6YDW""#
    static let timeout: TimeInterval = 30
    static let probeTimeout: TimeInterval = 8

    private let runner: any BoundedProcessRunning
    private let locator: SignedCLILocator
    private let signatures = SignatureCache()
    private let sourceEnvironment: [String: String]

    init(
        runner: any BoundedProcessRunning = BoundedProcessRunner(),
        locator: SignedCLILocator? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.locator = locator ?? SignedCLILocator(
            candidates: Self.candidateURLs(home: FileManager.default.homeDirectoryForCurrentUser),
            requirement: Self.designatedRequirement
        )
        sourceEnvironment = environment
    }

    static func candidateURLs(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
    }

    /// `~/.local/share/claude/versions/2.1.283` → "2.1.283".
    static func version(fromResolvedPath path: String) -> String? {
        guard path.contains("/claude/versions/") else { return nil }
        let last = (path as NSString).lastPathComponent
        return last.first?.isNumber == true ? last : nil
    }

    static func environment(from source: [String: String]) -> [String: String] {
        var environment = baseEnvironment(from: source)
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        environment["DISABLE_TELEMETRY"] = "1"
        return environment
    }

    /// Opus at low effort measured fastest and best calibrated in testing.
    /// No tools, MCP servers, settings, hooks or saved session; the short
    /// system prompt replaces Claude Code's default one (7× cheaper).
    static func arguments(for call: AIBriefCall) -> [String] {
        [
            "-p",
            "--output-format", "json",
            "--json-schema", String(data: call.schema, encoding: .utf8) ?? "{}",
            "--model", "opus",
            "--fallback-model", "sonnet",
            "--effort", "low",
            "--tools", "",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--no-session-persistence",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--max-budget-usd", "0.25",
            "--system-prompt", call.systemPrompt
        ]
    }

    func status() async -> AIProviderStatus {
        switch await signatures.location(for: locator) {
        case .notFound: return .notInstalled
        case .unverified: return .unverified
        case let .verified(url):
            let version = Self.version(fromResolvedPath: url.path)
            guard let workspace = try? makePrivateTemporaryDirectory(prefix: "SysBar-Claude-Probe") else {
                return .signInNeeded(version: version)
            }
            defer { try? FileManager.default.removeItem(at: workspace) }
            let command = BoundedProcessCommand(
                executableURL: url,
                arguments: ["auth", "status", "--json"],
                currentDirectoryURL: workspace,
                environment: Self.environment(from: sourceEnvironment),
                standardInput: Data(),
                standardInputLimit: 0,
                standardOutputLimit: 16 * 1_024,
                standardErrorLimit: 16 * 1_024,
                timeout: Self.probeTimeout
            )
            guard let output = try? await runner.run(command),
                  let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
                  (object["loggedIn"] as? Bool) == true else {
                return .signInNeeded(version: version)
            }
            return .ready(version: version)
        }
    }

    func run(_ call: AIBriefCall) async throws -> AIBriefResult {
        let url: URL
        switch await signatures.location(for: locator) {
        case .notFound: throw AIProviderError.notInstalled
        case .unverified: throw AIProviderError.unverified
        case let .verified(verified): url = verified
        }
        let workspace: URL
        do {
            workspace = try makePrivateTemporaryDirectory(prefix: "SysBar-Claude")
        } catch {
            throw AIProviderError.failed
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let command = BoundedProcessCommand(
            executableURL: url,
            arguments: Self.arguments(for: call),
            currentDirectoryURL: workspace,
            environment: Self.environment(from: sourceEnvironment),
            standardInput: Data(call.userMessage.utf8),
            standardInputLimit: 32 * 1_024,
            standardOutputLimit: 64 * 1_024,
            standardErrorLimit: 16 * 1_024,
            timeout: Self.timeout
        )
        let started = Date()
        let output: BoundedProcessOutput
        do {
            output = try await runner.run(command)
        } catch {
            throw mapRunnerError(error)
        }
        try Task.checkCancellation()
        guard !output.stdoutExceededLimit else { throw AIProviderError.invalidResponse }
        let parsed = try Self.parseEnvelope(output.stdout, exitStatus: output.terminationStatus, stderr: output.stderr)
        return AIBriefResult(
            object: parsed.object,
            durationSeconds: parsed.durationSeconds ?? Date().timeIntervalSince(started),
            modelLabel: parsed.modelLabel
        )
    }

    /// Reads `--output-format json`: `structured_output` holds the schema
    /// object; `is_error` with "Not logged in" means the user must sign in.
    static func parseEnvelope(
        _ data: Data,
        exitStatus: Int32,
        stderr: Data = Data()
    ) throws -> (object: Data, modelLabel: String, durationSeconds: Double?) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if isAuthenticationFailure(stderr) { throw AIProviderError.signInNeeded }
            throw exitStatus == 0 ? AIProviderError.invalidResponse : AIProviderError.failed
        }
        if (envelope["is_error"] as? Bool) == true {
            let message = ((envelope["result"] as? String) ?? "").lowercased()
            if ["not logged in", "/login", "invalid api key", "authentication", "oauth"].contains(where: message.contains) {
                throw AIProviderError.signInNeeded
            }
            if ["overloaded", "rate limit", "usage limit", "budget", "529", "too many"].contains(where: message.contains) {
                throw AIProviderError.busy
            }
            throw AIProviderError.failed
        }
        let object: Data
        if let structured = envelope["structured_output"] as? [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: structured) {
            object = encoded
        } else if let result = envelope["result"] as? String,
                  let encoded = result.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: encoded)) is [String: Any] {
            object = encoded
        } else {
            throw AIProviderError.invalidResponse
        }
        let models = ((envelope["modelUsage"] as? [String: Any])?.keys.map { $0.lowercased() }) ?? []
        let label = models.contains { $0.contains("opus") } ? "Opus"
            : models.contains { $0.contains("sonnet") } ? "Sonnet"
            : "Claude"
        let duration = (envelope["duration_ms"] as? Double).map { $0 / 1_000 }
        return (object, label, duration)
    }
}

// MARK: - Codex

actor CodexBriefProvider: BriefProviding {
    nonisolated let kind = AIProviderKind.codex

    static let designatedRequirement = #"identifier "codex" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "2DC432GLL2""#
    static let timeout: TimeInterval = 30
    static let probeTimeout: TimeInterval = 8

    static let disabledToolFeatures = [
        "shell_tool",
        "shell_snapshot",
        "unified_exec",
        "code_mode_host",
        "browser_use",
        "browser_use_external",
        "browser_use_full_cdp_access",
        "apps",
        "plugins",
        "hooks",
        "computer_use",
        "in_app_browser",
        "image_generation",
        "multi_agent",
        "remote_plugin",
        "skill_search",
        "tool_suggest",
        "view_image",
        "workspace_dependencies",
        "plugin_sharing",
        "auth_elicitation",
        "skill_mcp_dependency_install",
        "tool_call_mcp_elicitation",
        "goals"
    ]

    private let runner: any BoundedProcessRunning
    private let locator: SignedCLILocator
    private let signatures = SignatureCache()
    private let sourceEnvironment: [String: String]

    init(
        runner: any BoundedProcessRunning = BoundedProcessRunner(),
        locator: SignedCLILocator? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.locator = locator ?? SignedCLILocator(
            candidates: Self.candidateURLs(home: FileManager.default.homeDirectoryForCurrentUser),
            requirement: Self.designatedRequirement
        )
        sourceEnvironment = environment
    }

    static func candidateURLs(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
    }

    /// `…/releases/0.153.4-aarch64-apple-darwin/bin/codex` → "0.153.4".
    static func version(fromResolvedPath path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        guard let index = parts.firstIndex(of: "releases"), index + 1 < parts.count else { return nil }
        let release = parts[index + 1].components(separatedBy: "-").first ?? ""
        return release.first?.isNumber == true ? release : nil
    }

    static func environment(from source: [String: String]) -> [String: String] {
        var environment = baseEnvironment(from: source)
        if let codexHome = source["CODEX_HOME"], !codexHome.isEmpty { environment["CODEX_HOME"] = codexHome }
        return environment
    }

    /// The CLI's default model (named models are refused for ChatGPT
    /// accounts), low reasoning and the priority tier: 8.5 s measured. The
    /// user's own config, rules and tools are never loaded.
    static func arguments(
        schemaPath: String,
        lastMessagePath: String,
        workspacePath: String,
        priorityTier: Bool
    ) -> [String] {
        var arguments = [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--color", "never"
        ]
        for feature in Self.disabledToolFeatures {
            arguments += ["--disable", feature]
        }
        arguments += ["-c", #"model_reasoning_effort="low""#]
        if priorityTier { arguments += ["-c", #"service_tier="priority""#] }
        arguments += [
            "--output-schema", schemaPath,
            "-o", lastMessagePath,
            "-C", workspacePath,
            "-"
        ]
        return arguments
    }

    func status() async -> AIProviderStatus {
        switch await signatures.location(for: locator) {
        case .notFound: return .notInstalled
        case .unverified: return .unverified
        case let .verified(url):
            let version = Self.version(fromResolvedPath: url.path)
            guard let workspace = try? makePrivateTemporaryDirectory(prefix: "SysBar-Codex-Probe") else {
                return .signInNeeded(version: version)
            }
            defer { try? FileManager.default.removeItem(at: workspace) }
            let command = BoundedProcessCommand(
                executableURL: url,
                arguments: ["login", "status"],
                currentDirectoryURL: workspace,
                environment: Self.environment(from: sourceEnvironment),
                standardInput: Data(),
                standardInputLimit: 0,
                standardOutputLimit: 16 * 1_024,
                standardErrorLimit: 16 * 1_024,
                timeout: Self.probeTimeout
            )
            guard let output = try? await runner.run(command), output.terminationStatus == 0 else {
                return .signInNeeded(version: version)
            }
            let text = (String(data: output.stdout + output.stderr, encoding: .utf8) ?? "").lowercased()
            return text.contains("logged in") && !text.contains("not logged in")
                ? .ready(version: version)
                : .signInNeeded(version: version)
        }
    }

    func run(_ call: AIBriefCall) async throws -> AIBriefResult {
        do {
            return try await run(call, priorityTier: true)
        } catch AIProviderError.busy {
            // The priority tier is an entitlement; fall back to the default tier once.
            return try await run(call, priorityTier: false)
        }
    }

    private func run(_ call: AIBriefCall, priorityTier: Bool) async throws -> AIBriefResult {
        let url: URL
        switch await signatures.location(for: locator) {
        case .notFound: throw AIProviderError.notInstalled
        case .unverified: throw AIProviderError.unverified
        case let .verified(verified): url = verified
        }
        let root: URL
        do {
            root = try makePrivateTemporaryDirectory(prefix: "SysBar-Codex")
        } catch {
            throw AIProviderError.failed
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let schemaURL = root.appendingPathComponent("schema.json")
        let lastMessageURL = root.appendingPathComponent("last-message.json")
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try call.schema.write(to: schemaURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schemaURL.path)
        } catch {
            throw AIProviderError.failed
        }

        // Codex has no system-prompt flag: the instructions lead the stdin task.
        let input = "Instructions:\n\(call.systemPrompt)\n\nTask:\n\(call.userMessage)"
        let command = BoundedProcessCommand(
            executableURL: url,
            arguments: Self.arguments(
                schemaPath: schemaURL.path,
                lastMessagePath: lastMessageURL.path,
                workspacePath: workspace.path,
                priorityTier: priorityTier
            ),
            currentDirectoryURL: workspace,
            environment: Self.environment(from: sourceEnvironment),
            standardInput: Data(input.utf8),
            standardInputLimit: 40 * 1_024,
            standardOutputLimit: 64 * 1_024,
            standardErrorLimit: 32 * 1_024,
            timeout: Self.timeout
        )
        let started = Date()
        let output: BoundedProcessOutput
        do {
            output = try await runner.run(command)
        } catch {
            throw mapRunnerError(error)
        }
        try Task.checkCancellation()
        guard output.terminationStatus == 0 else {
            if isAuthenticationFailure(output.stderr) { throw AIProviderError.signInNeeded }
            let message = (String(data: output.stderr, encoding: .utf8) ?? "").lowercased()
            if priorityTier, message.contains("service_tier") || message.contains("service tier") {
                throw AIProviderError.busy
            }
            if ["rate limit", "usage limit", "too many requests", "overloaded"].contains(where: message.contains) {
                throw AIProviderError.busy
            }
            throw AIProviderError.failed
        }
        guard let data = try? Data(contentsOf: lastMessageURL), data.count <= 64 * 1_024 else {
            throw AIProviderError.invalidResponse
        }
        return AIBriefResult(
            object: try Self.extractObject(from: data),
            durationSeconds: Date().timeIntervalSince(started),
            modelLabel: "Codex"
        )
    }

    /// The last message should be the bare schema object; tolerate a code fence.
    static func extractObject(from data: Data) throws -> Data {
        var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.hasPrefix("```") {
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = text.range(of: "```", options: .backwards) { text = String(text[..<fence.lowerBound]) }
        }
        guard let object = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: object)) is [String: Any] else {
            throw AIProviderError.invalidResponse
        }
        return object
    }
}

// MARK: - Choosing a provider

enum AIProviderPolicy {
    static let selectionKey = "AIBriefProvider"

    /// First run: Claude when both are installed, otherwise the one that is,
    /// otherwise Off. After that, the user's choice is never changed for them.
    static func defaultKind(claude: AIProviderStatus, codex: AIProviderStatus) -> AIProviderKind {
        if claude.isInstalled { return .claude }
        if codex.isInstalled { return .codex }
        return .off
    }

    static func modelInfo(_ kind: AIProviderKind) -> String {
        switch kind {
        case .claude: return AppResources.localized("provider.model.claude", fallback: "Opus · fast")
        case .codex: return AppResources.localized("provider.model.codex", fallback: "Codex · fast")
        case .off: return ""
        }
    }

    static func caption(_ kind: AIProviderKind, status: AIProviderStatus) -> String {
        switch status {
        case .checking:
            return AppResources.localized("provider.state.probing", fallback: "Checking…")
        case .notInstalled:
            return AppResources.localized("provider.state.notInstalled", fallback: "Not installed")
        case .unverified:
            return AppResources.localized("provider.state.unverified", fallback: "Unverified build — not used")
        case let .signInNeeded(version):
            return AppResources.formatted(
                kind == .claude ? "provider.state.signInNeeded.claude" : "provider.state.signInNeeded.codex",
                fallback: kind == .claude ? "%@ · sign in needed (run claude in Terminal)" : "%@ · sign in needed (run codex login)",
                version ?? kind.displayName
            )
        case let .ready(version):
            return AppResources.formatted(
                "provider.state.ready",
                fallback: "%1$@ %2$@ · signed in · %3$@",
                kind.displayName,
                version ?? "",
                modelInfo(kind)
            )
        }
    }
}
