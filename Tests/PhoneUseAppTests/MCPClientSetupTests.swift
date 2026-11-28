import Foundation
import XCTest
@testable import PhoneUseApp

@MainActor
final class MCPClientSetupTests: XCTestCase {
    private let serverPath = "/Applications/phone use.app/Contents/Helpers/phone-use-mcp"
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCommandsMatchEachClientsCLI() {
        let setup = MCPClientSetup(serverPath: serverPath)
        XCTAssertEqual(setup.addArguments(.claudeCode), ["mcp", "add", "-s", "user", "phone-use", "--", serverPath])
        XCTAssertEqual(setup.removeArguments(.claudeCode), ["mcp", "remove", "-s", "user", "phone-use"])
        XCTAssertEqual(setup.addArguments(.codex), ["mcp", "add", "phone-use", "--", serverPath])
        XCTAssertEqual(setup.removeArguments(.codex), ["mcp", "remove", "phone-use"])
        XCTAssertEqual(setup.getArguments(.codex), ["mcp", "get", "phone-use"])
        XCTAssertEqual(setup.addArguments(.codeBuddyCode), ["mcp", "add", "--scope", "user", "phone-use", "--", serverPath])
        XCTAssertEqual(setup.removeArguments(.codeBuddyCode), ["mcp", "remove", "phone-use", "--scope", "user"])
        XCTAssertEqual(setup.shellCommand(.codex),
                       "codex mcp add phone-use -- '/Applications/phone use.app/Contents/Helpers/phone-use-mcp'")
    }

    func testShellQuotingKeepsPlainPathsReadable() {
        XCTAssertEqual(MCPClientSetup.shellQuoted("/Applications/PhoneUse.app/Contents/Helpers/phone-use-mcp"),
                       "/Applications/PhoneUse.app/Contents/Helpers/phone-use-mcp")
        XCTAssertEqual(MCPClientSetup.shellQuoted("it's here"), #"'it'\''s here'"#)
        XCTAssertEqual(MCPClientSetup.shellQuoted(""), "''")
    }

    func testJSONConfigurationIsAnMCPServersEntry() throws {
        let json = MCPClientSetup(serverPath: serverPath).jsonConfiguration
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let server = (object?["mcpServers"] as? [String: Any])?["phone-use"] as? [String: Any]
        XCTAssertEqual(server?["command"] as? String, serverPath)
        XCTAssertFalse(json.contains(#"\/"#), "paths stay readable")
    }

    func testCursorInstallLinkCarriesTheServerCommand() throws {
        let path = "/Applications/测试 ~~~??? & #1.app/Contents/Helpers/phone-use-mcp"
        let url = try XCTUnwrap(MCPClientSetup(serverPath: path).cursorInstallURL)
        let link = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(link.scheme, "cursor")
        XCTAssertEqual(link.host, "anysphere.cursor-deeplink")
        XCTAssertEqual(link.path, "/mcp/install")
        XCTAssertEqual(link.queryItems?.first { $0.name == "name" }?.value, "phone-use")
        XCTAssertFalse(url.absoluteString.contains("+"), "Form-style query decoders treat a literal plus as a space")
        let config = try XCTUnwrap(link.queryItems?.first { $0.name == "config" }?.value)
        let data = try XCTUnwrap(Data(base64Encoded: config))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: data), ["command": path])
    }

    func testServerIsFoundInTheBundleOrNextToASwiftPMBuild() throws {
        let app = directory.appendingPathComponent("PhoneUse.app")
        let helper = app.appendingPathComponent("Contents/Helpers/phone-use-mcp")
        try makeExecutable(helper, "#!/bin/sh\n")
        XCTAssertEqual(MCPClientSetup.serverURL(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/PhoneUse")), helper)

        let build = directory.appendingPathComponent("debug")
        XCTAssertNil(MCPClientSetup.serverURL(bundleURL: build, executableURL: build.appendingPathComponent("PhoneUse.app")))
        let sibling = build.appendingPathComponent("phone-use-mcp")
        try makeExecutable(sibling, "#!/bin/sh\n")
        XCTAssertEqual(MCPClientSetup.serverURL(bundleURL: build, executableURL: build.appendingPathComponent("PhoneUse.app")), sibling)
    }

    func testLoginShellPathIgnoresWhatShellStartupPrints() {
        let output = "Welcome back!\n__PHONE_USE_PATH__/opt/homebrew/bin:/Users/me/.local/bin::/usr/bin__PHONE_USE_PATH__"
        XCTAssertEqual(CommandLineTools.parseLoginShellPath(output), ["/opt/homebrew/bin", "/Users/me/.local/bin", "/usr/bin"])
        XCTAssertNil(CommandLineTools.parseLoginShellPath("no markers"))
    }

    func testSearchPathComesFromTheLoginShellFirst() async throws {
        // Stands in for the user's shell: runs the script with a PATH only a login shell would set.
        let shell = directory.appendingPathComponent("fake-shell")
        try makeExecutable(shell, """
        #!/bin/sh
        echo "motd noise"
        PATH="/login/one:/login/two:/usr/bin:/bin" exec /bin/sh -c "$2"
        """)
        let previous = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
        defer { if let previous { setenv("SHELL", previous, 1) } else { unsetenv("SHELL") } }

        let path = await CommandLineTools.searchPath()
        XCTAssertEqual(Array(path.prefix(2)), ["/login/one", "/login/two"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"), "common install locations are still searched")
    }

    func testMissingCLIIsReportedWithoutRunningAnything() async {
        let installer = MCPClientInstaller(setup: MCPClientSetup(serverPath: serverPath), searchPath: { [directory] in [directory!.path, "/usr/bin", "/bin"] })
        await installer.refresh()
        XCTAssertEqual(installer.state(.claudeCode).status, .toolMissing)
        XCTAssertEqual(installer.state(.codex).status, .toolMissing)
        XCTAssertTrue(installer.installedCLIs.isEmpty)
    }

    func testOnlyInstalledClientsAppearAndRemovalIsDetected() async throws {
        let tool = directory.appendingPathComponent("codebuddy")
        try makeExecutable(tool, "#!/bin/sh\nexit 1\n")
        // An executable directory is not a CLI.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("codex"), withIntermediateDirectories: false)
        var apps: Set<MCPClientSetup.DesktopClient> = [.workBuddy, .codeBuddy]
        let installer = MCPClientInstaller(setup: MCPClientSetup(serverPath: serverPath),
                                          searchPath: { [directory] in [directory!.path] },
                                          appInstalled: { apps.contains($0) })
        await installer.refresh()
        XCTAssertEqual(installer.installedCLIs, [.codeBuddyCode])
        XCTAssertEqual(Set(installer.installedApps), apps)

        try FileManager.default.removeItem(at: tool)
        apps = [.cursor]
        await installer.refresh()
        XCTAssertTrue(installer.installedCLIs.isEmpty)
        XCTAssertEqual(installer.installedApps, [.cursor])
    }

    func testBuddyImportCreatesAndUpdatesOnlyThePhoneUseEntry() throws {
        XCTAssertEqual(MCPClientSetup.DesktopClient.codeBuddy.configPath, ".codebuddy/mcp.json")
        XCTAssertEqual(MCPClientSetup.DesktopClient.workBuddy.configPath, ".workbuddy/mcp.json")
        let setup = MCPClientSetup(serverPath: serverPath)
        for client in [MCPClientSetup.DesktopClient.codeBuddy, .workBuddy] {
            let url = directory.appendingPathComponent(try XCTUnwrap(client.configPath))
            try setup.install(in: url)
            let original = try Data(contentsOf: url)
            try setup.install(in: url)
            XCTAssertEqual(try Data(contentsOf: url), original)
            try #"{"flag":true,"mcpServers":{"other":{"url":"https://example.com"},"phone-use":{"command":"old","disabled":true}}}"#
                .write(to: url, atomically: true, encoding: .utf8)
            try setup.install(in: url)
            let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let servers = try XCTUnwrap(config["mcpServers"] as? [String: [String: Any]])
            XCTAssertEqual(config["flag"] as? Bool, true)
            XCTAssertEqual(servers["other"]?["url"] as? String, "https://example.com")
            XCTAssertEqual(servers["phone-use"]?["command"] as? String, serverPath)
            XCTAssertEqual(servers["phone-use"]?["disabled"] as? Bool, true)
        }
    }

    func testBuddyImportLeavesUnreadableConfigurationsIntact() throws {
        let url = directory.appendingPathComponent("mcp.json")
        for content in ["invalid", "[]", #"{"mcpServers":[]}"#] {
            try content.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try MCPClientSetup(serverPath: serverPath).install(in: url))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), content)
        }
    }

    func testAddReplacesAnOldEntryAndReportsItAdded() async throws {
        let log = directory.appendingPathComponent("calls.log")
        let config = directory.appendingPathComponent("configured")
        // A stand-in for `codex`: remembers the configured command like the real CLI does.
        try makeExecutable(directory.appendingPathComponent("codex"), """
        #!/bin/sh
        echo "$@" >> '\(log.path)'
        case "$2" in
          get) [ -f '\(config.path)' ] || { echo "Error: No MCP server named 'phone-use' found."; exit 1; }
               echo "phone-use"; echo "  command: $(cat '\(config.path)')" ;;
          remove) rm -f '\(config.path)'; echo "Removed" ;;
          add) printf '%s' "$5" > '\(config.path)'; echo "Added" ;;
        esac
        """)
        try "/Applications/DeviceHub.app/Contents/Helpers/devicehub-mcp".write(to: config, atomically: true, encoding: .utf8)
        let installer = MCPClientInstaller(setup: MCPClientSetup(serverPath: serverPath), searchPath: { [directory] in [directory!.path, "/usr/bin", "/bin"] })

        await installer.refresh()
        XCTAssertEqual(installer.state(.codex).status, .addedElsewhere)

        await installer.add(.codex)
        XCTAssertEqual(installer.state(.codex).status, .added)
        XCTAssertFalse(installer.state(.codex).failed)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), serverPath)
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(calls.suffix(3), ["mcp remove phone-use", "mcp add phone-use -- \(serverPath)", "mcp get phone-use"])
    }

    func testFailedAddShowsTheCLIOutput() async throws {
        try makeExecutable(directory.appendingPathComponent("claude"), """
        #!/bin/sh
        [ "$2" = add ] && { echo "Invalid scope: user" >&2; exit 2; }
        exit 1
        """)
        let installer = MCPClientInstaller(setup: MCPClientSetup(serverPath: serverPath), searchPath: { [directory] in [directory!.path, "/usr/bin", "/bin"] })
        await installer.refresh()
        XCTAssertEqual(installer.state(.claudeCode).status, .notAdded)

        await installer.add(.claudeCode)
        XCTAssertEqual(installer.state(.claudeCode).status, .notAdded)
        XCTAssertTrue(installer.state(.claudeCode).failed)
        XCTAssertEqual(installer.state(.claudeCode).message, "添加失败：Invalid scope: user")
    }

    private func makeExecutable(_ url: URL, _ contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
