import XCTest
@testable import ShellX

@MainActor
final class AppViewModelTests: XCTestCase {
    func testDuplicateSessionCreatesNewIdentifier() {
        let viewModel = AppViewModel(repository: AppStorageRepository())
        let source = SSHSessionProfile(
            name: "test",
            host: "127.0.0.1",
            username: "root",
            authMethod: .password,
            passwordStoredInKeychain: true
        )
        viewModel.sessions = [source]

        viewModel.duplicateSession(source)

        XCTAssertEqual(viewModel.sessions.count, 2)
        XCTAssertNotEqual(viewModel.sessions[0].id, viewModel.sessions[1].id)
        XCTAssertTrue(viewModel.sessions.contains(where: { $0.name == "test-副本" }))
        XCTAssertFalse(viewModel.sessions.contains(where: { $0.name == "test-副本" && $0.passwordStoredInKeychain }))
    }

    func testDeleteFolderMovesChildrenAndSessionsToParent() {
        let viewModel = AppViewModel(repository: AppStorageRepository())
        let root = SessionFolder(name: "root")
        let child = SessionFolder(parentID: root.id, name: "child")
        let session = SSHSessionProfile(folderID: child.id, name: "vm", host: "10.0.0.1", username: "ops")

        viewModel.folders = [root, child]
        viewModel.sessions = [session]

        viewModel.deleteFolder(child)

        XCTAssertEqual(viewModel.folders.count, 1)
        XCTAssertEqual(viewModel.sessions.first?.folderID, root.id)
    }

    func testSelectedSessionOnlyReturnsVisibleSession() {
        let viewModel = AppViewModel(repository: AppStorageRepository())
        let production = SessionFolder(name: "production")
        let staging = SessionFolder(name: "staging")
        let visible = SSHSessionProfile(folderID: production.id, name: "prod", host: "10.0.0.2", username: "ops")
        let hidden = SSHSessionProfile(folderID: staging.id, name: "staging", host: "10.0.0.3", username: "ops")

        viewModel.folders = [production, staging]
        viewModel.sessions = [visible, hidden]
        viewModel.selectedSessionID = hidden.id
        viewModel.selectedFolderID = production.id

        XCTAssertNil(viewModel.selectedSession)

        viewModel.syncSelectionToVisibleSessions()

        XCTAssertEqual(viewModel.selectedSession?.id, visible.id)
    }

    func testPrivateKeySessionRequiresKeyPathAndValidPort() {
        let valid = SSHSessionProfile(
            name: "key-session",
            host: "example.com",
            port: 22,
            username: "dev",
            authMethod: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519"
        )
        let missingKey = SSHSessionProfile(
            name: "missing-key",
            host: "example.com",
            port: 22,
            username: "dev",
            authMethod: .privateKey,
            privateKeyPath: ""
        )
        let invalidPort = SSHSessionProfile(
            name: "bad-port",
            host: "example.com",
            port: 0,
            username: "dev",
            authMethod: .sshAgent
        )

        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(missingKey.isValid)
        XCTAssertFalse(invalidPort.isValid)
    }

    func testPasswordSessionRequiresUsername() {
        let valid = SSHSessionProfile(
            name: "password-session",
            host: "example.com",
            port: 22,
            username: "dev",
            authMethod: .password,
            passwordStoredInKeychain: true
        )
        let missingUsername = SSHSessionProfile(
            name: "password-session",
            host: "example.com",
            port: 22,
            username: "",
            authMethod: .password,
            passwordStoredInKeychain: true
        )

        XCTAssertTrue(valid.isValid)
        XCTAssertFalse(missingUsername.isValid)
    }

    func testSwiftTermSSHArgumentsContainPrivateKeyAndStartupCommand() {
        let session = SSHSessionProfile(
            name: "prod",
            host: "example.com",
            port: 2222,
            username: "ops",
            authMethod: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519",
            useKeychainForPrivateKey: true,
            startupCommand: "cd /srv/app"
        )

        let args = TerminalSessionViewModel.sshArguments(for: session, userKnownHostsPath: "/tmp/shellx-known_hosts")

        XCTAssertEqual(args.prefix(3), ["-tt", "-p", "2222"])
        XCTAssertTrue(args.contains("UserKnownHostsFile=/tmp/shellx-known_hosts"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(args.contains("UseKeychain=yes"))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("ops@example.com"))
        XCTAssertEqual(args.last, "cd /srv/app")
    }

    func testPasswordSSHArgumentsPreferPasswordAuthentication() {
        let session = SSHSessionProfile(
            name: "prod-password",
            host: "example.com",
            port: 22,
            username: "ops",
            authMethod: .password,
            passwordStoredInKeychain: true
        )

        let args = TerminalSessionViewModel.sshArguments(for: session, userKnownHostsPath: "/tmp/shellx-known_hosts")

        XCTAssertTrue(args.contains("PreferredAuthentications=password,keyboard-interactive"))
        XCTAssertTrue(args.contains("PubkeyAuthentication=no"))
        XCTAssertTrue(args.contains("NumberOfPasswordPrompts=1"))
        XCTAssertTrue(args.contains("ops@example.com"))
    }

    func testSessionProfileDecodeBackfillsUseKeychainDefault() throws {
        let json = """
        {
          "folders": [],
          "sessions": [
            {
              "id": "0E8C22CE-D6CB-4A2A-9A77-0B67B06DCDB6",
              "name": "legacy",
              "host": "example.com",
              "port": 22,
              "username": "ops",
              "authMethod": "privateKey",
              "privateKeyPath": "~/.ssh/id_ed25519",
              "startupCommand": "",
              "notes": ""
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let workspace = try decoder.decode(SessionWorkspace.self, from: Data(json.utf8))

        XCTAssertEqual(workspace.sessions.count, 1)
        XCTAssertFalse(workspace.sessions[0].useKeychainForPrivateKey)
        XCTAssertFalse(workspace.sessions[0].passwordStoredInKeychain)
    }

    func testOpenAndCloseTerminalTabsUpdatesActiveSession() {
        let viewModel = AppViewModel(repository: AppStorageRepository())
        let first = SSHSessionProfile(name: "first", host: "10.0.0.1", username: "ops")
        let second = SSHSessionProfile(name: "second", host: "10.0.0.2", username: "ops")
        viewModel.sessions = [first, second]

        viewModel.openTerminal(sessionID: first.id)
        viewModel.openTerminal(sessionID: second.id)

        XCTAssertEqual(viewModel.openTerminalSessionIDs, [first.id, second.id])
        XCTAssertEqual(viewModel.activeTerminalSessionID, second.id)

        viewModel.closeTerminal(sessionID: second.id)

        XCTAssertEqual(viewModel.openTerminalSessionIDs, [first.id])
        XCTAssertEqual(viewModel.activeTerminalSessionID, first.id)
    }

    func testOpenTerminalReusesExistingTabAndActivatesSelection() {
        let viewModel = AppViewModel(repository: AppStorageRepository())
        let session = SSHSessionProfile(name: "prod", host: "example.com", username: "ops")
        viewModel.sessions = [session]

        viewModel.openTerminal(sessionID: session.id)
        viewModel.openTerminal(sessionID: session.id)

        XCTAssertEqual(viewModel.openTerminalSessionIDs, [session.id])
        XCTAssertEqual(viewModel.activeTerminalSessionID, session.id)
        XCTAssertEqual(viewModel.selectedSessionID, session.id)
    }

    func testZModemTriggerDetectorRecognizesUploadPrompt() {
        var detector = ZModemTriggerDetector()
        let data = Data("rz waiting to receive.**B0100".utf8)

        let trigger = detector.consume(data)

        XCTAssertEqual(trigger, .uploadRequest)
    }

    func testZModemTriggerDetectorRecognizesBareUploadHandshake() {
        var detector = ZModemTriggerDetector()
        let data = Data("**B0100000023be50".utf8)

        let trigger = detector.consume(data)

        XCTAssertEqual(trigger, .uploadRequest)
    }

    func testZModemTriggerDetectorRecognizesFragmentedUploadHandshake() {
        var detector = ZModemTriggerDetector()

        XCTAssertNil(detector.consume(Data("**B010000".utf8)))

        let trigger = detector.consume(Data("023be50eive.**B0100000023be50".utf8))

        XCTAssertEqual(trigger, .uploadRequest)
    }

    func testZModemTriggerDetectorRecognizesUploadHandshakeWithControlBytes() {
        var detector = ZModemTriggerDetector()
        let data = Data([0x18, 0x18] + Array("**B0100000023be50".utf8) + [0x0D, 0x00, 0x18])

        let trigger = detector.consume(data)

        XCTAssertEqual(trigger, .uploadRequest)
    }

    func testZModemTriggerDetectorRecognizesDownloadPrompt() {
        var detector = ZModemTriggerDetector()
        let data = Data("**B00000000000000".utf8)

        let trigger = detector.consume(data)

        XCTAssertEqual(trigger, .downloadRequest)
    }

    func testZModemTriggerDetectorPrefersDownloadWhenLastCommandWasSz() {
        var detector = ZModemTriggerDetector()
        let data = Data("**B0100000063f694".utf8)

        let trigger = detector.consume(data, preferredDirection: .downloadFromRemote)

        XCTAssertEqual(trigger, .downloadRequest)
    }

    func testZModemTriggerDetectorPrefersUploadWhenLastCommandWasRz() {
        var detector = ZModemTriggerDetector()
        let data = Data("**B0100000023be50".utf8)

        let trigger = detector.consume(data, preferredDirection: .uploadToRemote)

        XCTAssertEqual(trigger, .uploadRequest)
    }

    func testSanitizedTransferSeedDropsPromptBeforeDownloadHandshake() {
        let raw = Data("(base) dylan@dev:~$ sz file\r\n**B00000000000000".utf8)

        let sanitized = SSHPTYTransport.sanitizedTransferSeed(from: raw, trigger: .downloadRequest)

        XCTAssertEqual(String(decoding: sanitized, as: UTF8.self), "**B00000000000000")
    }

    func testSanitizedTransferSeedDropsPromptBeforeUploadHandshake() {
        let raw = Data("rz waiting to receive.**B0100000023be50".utf8)

        let sanitized = SSHPTYTransport.sanitizedTransferSeed(from: raw, trigger: .uploadRequest)

        XCTAssertEqual(String(decoding: sanitized, as: UTF8.self), "**B0100000023be50")
    }

    func testDownloadCompletionFrameDetectionRecognizesB08Trailer() {
        let trailer = Data([0x2A, 0x2A, 0x18] + Array("B0800000000022d".utf8) + [0x0D])

        XCTAssertTrue(SSHPTYTransport.containsDownloadCompletionFrame(in: trailer))
    }

    func testDownloadCompletionFrameDetectionIgnoresRegularPayload() {
        let payload = Data("hi".utf8)

        XCTAssertFalse(SSHPTYTransport.containsDownloadCompletionFrame(in: payload))
    }

    func testZModemHelperLocatorReturnsNilForUnknownCommand() {
        XCTAssertNil(ZModemHelperLocator.path(named: "shellx-not-a-real-command"))
    }
}
