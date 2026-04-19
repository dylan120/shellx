import XCTest
import AppKit
@testable import ShellX

@MainActor
final class AppViewModelTests: XCTestCase {
    func testControlCNormalizesToInterruptByte() {
        XCTAssertEqual(
            TerminalKeyInputNormalizer.controlSequence(
                forKeyCode: 8,
                modifiers: [.control]
            ),
            [0x03]
        )

        XCTAssertNil(
            TerminalKeyInputNormalizer.controlSequence(
                forKeyCode: 8,
                modifiers: [.command, .control]
            )
        )

        XCTAssertNil(
            TerminalKeyInputNormalizer.controlSequence(
                forKeyCode: 8,
                modifiers: [.option, .control]
            )
        )
    }

    func testCSIUControlSequencesNormalizeBeforePTYWrite() {
        XCTAssertEqual(
            TerminalKeyInputNormalizer.normalizedTerminalInput(Data([0x1B] + Array("[99;5u".utf8))),
            Data([0x03])
        )

        XCTAssertEqual(
            TerminalKeyInputNormalizer.normalizedTerminalInput(Data([0x1B] + Array("[99;5:3u".utf8))),
            Data()
        )

        XCTAssertEqual(
            TerminalKeyInputNormalizer.normalizedTerminalInput(Data([0x1B] + Array("[98;5u".utf8))),
            Data([0x02])
        )

        let shiftedSequence = Data([0x1B] + Array("[99;6u".utf8))
        XCTAssertEqual(
            TerminalKeyInputNormalizer.normalizedTerminalInput(shiftedSequence),
            shiftedSequence
        )
    }

    func testAppearancePreferenceRoundTripsSupportedModes() {
        let originalValue = ShellXPreferences.appearanceMode
        defer {
            ShellXPreferences.appearanceMode = originalValue
        }

        ShellXPreferences.appearanceMode = .dark
        XCTAssertEqual(ShellXPreferences.appearanceMode, .dark)

        ShellXPreferences.appearanceMode = .light
        XCTAssertEqual(ShellXPreferences.appearanceMode, .light)

        ShellXPreferences.appearanceMode = .system
        XCTAssertEqual(ShellXPreferences.appearanceMode, .system)
    }

    func testTerminalScrollbackPreferenceClampsToSupportedRange() {
        let originalValue = ShellXPreferences.terminalScrollbackLines
        defer {
            ShellXPreferences.terminalScrollbackLines = originalValue
        }

        ShellXPreferences.terminalScrollbackLines = ShellXPreferences.minimumTerminalScrollbackLines - 1
        XCTAssertEqual(
            ShellXPreferences.terminalScrollbackLines,
            ShellXPreferences.minimumTerminalScrollbackLines
        )

        ShellXPreferences.terminalScrollbackLines = ShellXPreferences.maximumTerminalScrollbackLines + 1
        XCTAssertEqual(
            ShellXPreferences.terminalScrollbackLines,
            ShellXPreferences.maximumTerminalScrollbackLines
        )
    }

    func testPTYInitialWindowSizeUsesTerminalDimensionsWhenAvailable() {
        let windowSize = SSHPTYTransport.normalizedWindowSize((cols: 132, rows: 48))

        XCTAssertEqual(windowSize.cols, 132)
        XCTAssertEqual(windowSize.rows, 48)
    }

    func testPTYInitialWindowSizeFallsBackAndClampsInvalidValues() {
        let fallbackWindowSize = SSHPTYTransport.normalizedWindowSize(nil)
        let clampedWindowSize = SSHPTYTransport.normalizedWindowSize((cols: 0, rows: Int(UInt16.max) + 10))

        XCTAssertEqual(fallbackWindowSize.cols, 120)
        XCTAssertEqual(fallbackWindowSize.rows, 40)
        XCTAssertEqual(clampedWindowSize.cols, 1)
        XCTAssertEqual(clampedWindowSize.rows, Int(UInt16.max))
    }

    func testAutomaticUpdatePreferenceRoundTrips() {
        let originalValue = ShellXPreferences.automaticUpdatesEnabled
        defer {
            ShellXPreferences.automaticUpdatesEnabled = originalValue
        }

        ShellXPreferences.automaticUpdatesEnabled = true
        XCTAssertTrue(ShellXPreferences.automaticUpdatesEnabled)

        ShellXPreferences.automaticUpdatesEnabled = false
        XCTAssertFalse(ShellXPreferences.automaticUpdatesEnabled)
    }

    func testUserScriptRequiresNameAndContent() {
        XCTAssertTrue(UserScript(name: "检查磁盘", content: "df -h").isValid)
        XCTAssertFalse(UserScript(name: "", content: "df -h").isValid)
        XCTAssertFalse(UserScript(name: "检查磁盘", content: "   ").isValid)
    }

    func testBatchScriptPasswordSessionFailsBeforeStartingSSHProcess() async {
        let service = ScriptBatchExecutionService()
        let script = UserScript(name: "检查", content: "hostname")
        let session = SSHSessionProfile(
            name: "password-session",
            host: "example.com",
            username: "ops",
            authMethod: .password
        )

        let result = await service.execute(script: script, session: session)

        if case .failed(let message) = result.status {
            XCTAssertTrue(message.contains("暂不支持账号密码认证"))
        } else {
            XCTFail("账号密码认证会话不应进入批量 SSH 执行")
        }
    }

    func testReopenTerminalTabsAfterMainWindowClosePreferenceRoundTrips() {
        let originalValue = ShellXPreferences.reopenTerminalTabsAfterMainWindowClose
        defer {
            ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = originalValue
        }

        ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = true
        XCTAssertTrue(ShellXPreferences.reopenTerminalTabsAfterMainWindowClose)

        ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = false
        XCTAssertFalse(ShellXPreferences.reopenTerminalTabsAfterMainWindowClose)
    }

    func testUpdateVersionComparisonHandlesTagsAndDifferentComponentCounts() {
        XCTAssertEqual(AppUpdateService.compareVersions("v1.2.1", "1.2.0"), .orderedDescending)
        XCTAssertEqual(AppUpdateService.compareVersions("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(AppUpdateService.compareVersions("1.2.0", "1.10.0"), .orderedAscending)
    }

    func testOpenLocalTerminalUsesFixedTabIdentifier() {
        let viewModel = AppViewModel(repository: AppStorageRepository())

        viewModel.openLocalTerminal()

        XCTAssertEqual(viewModel.openTerminalTabs.map(\.id), [AppViewModel.localTerminalID])
        XCTAssertEqual(viewModel.activeTerminalTabID, AppViewModel.localTerminalID)
        XCTAssertEqual(viewModel.openTerminalTabs.first?.title, "本机终端")
        XCTAssertEqual(
            viewModel.openTerminalTabs.first?.kind,
            .local(shellPath: AppViewModel.defaultLocalShellPath, launchMode: .interactive)
        )
    }

    func testDuplicateLocalTerminalUsesNonLoginShell() {
        let viewModel = AppViewModel(repository: AppStorageRepository())

        viewModel.openLocalTerminal()
        viewModel.duplicateTerminal(tabID: AppViewModel.localTerminalID)

        XCTAssertEqual(viewModel.openTerminalTabs.count, 2)
        XCTAssertEqual(
            viewModel.openTerminalTabs.last?.kind,
            .local(shellPath: AppViewModel.defaultLocalShellPath, launchMode: .interactive)
        )
    }

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

    func testSFTPArgumentsReusePrivateKeyAndKnownHostsOptions() {
        let session = SSHSessionProfile(
            name: "prod-sftp",
            host: "example.com",
            port: 2222,
            username: "ops",
            authMethod: .privateKey,
            privateKeyPath: "~/.ssh/id_ed25519",
            useKeychainForPrivateKey: true
        )

        let args = SFTPTransferService.sftpArguments(
            for: session,
            userKnownHostsPath: "/tmp/shellx-known_hosts"
        )

        XCTAssertEqual(args.prefix(2), ["-P", "2222"])
        XCTAssertTrue(args.contains("UserKnownHostsFile=/tmp/shellx-known_hosts"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=no"))
        XCTAssertTrue(args.contains("UseKeychain=yes"))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
        XCTAssertTrue(args.contains("-i"))
        XCTAssertTrue(args.contains("ops@example.com"))
    }

    func testSFTPCommandScriptUsesRecursivePutForDirectories() {
        let operation = SFTPOperation.upload(
            localURL: URL(fileURLWithPath: "/tmp/demo-folder", isDirectory: true),
            remoteDirectory: "/srv/uploads"
        )

        let script = SFTPTransferService.commandScript(for: operation)

        XCTAssertTrue(script.contains("put -r"))
        XCTAssertTrue(script.contains("\"/tmp/demo-folder\""))
        XCTAssertTrue(script.contains("\"/srv/uploads\""))
        XCTAssertTrue(script.hasSuffix("bye\n"))
    }

    func testSFTPCommandScriptDistinguishesFileAndDirectoryDownloads() {
        let fileScript = SFTPTransferService.commandScript(
            for: .downloadFile(
                remotePath: "/srv/file.txt",
                localDirectory: URL(fileURLWithPath: "/tmp")
            )
        )
        let directoryScript = SFTPTransferService.commandScript(
            for: .downloadDirectory(
                remotePath: "/srv/assets",
                localDirectory: URL(fileURLWithPath: "/tmp")
            )
        )

        XCTAssertTrue(fileScript.contains("get \"/srv/file.txt\""))
        XCTAssertFalse(fileScript.contains("get -r"))
        XCTAssertTrue(directoryScript.contains("get -r \"/srv/assets\""))
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

        XCTAssertEqual(viewModel.openTerminalTabs.count, 2)
        XCTAssertEqual(viewModel.openTerminalTabs.map(\.title), ["first", "second"])
        XCTAssertEqual(viewModel.openTerminalTabs.last?.id, viewModel.activeTerminalTabID)

        let secondTabID = viewModel.openTerminalTabs.last!.id
        viewModel.closeTerminal(tabID: secondTabID)

        XCTAssertEqual(viewModel.openTerminalTabs.count, 1)
        XCTAssertEqual(viewModel.openTerminalTabs.first?.title, "first")
        XCTAssertEqual(viewModel.openTerminalTabs.first?.id, viewModel.activeTerminalTabID)
    }

    func testOpenTerminalCreatesIndependentTabsAndActivatesSelection() {
        let viewModel = AppViewModel(repository: AppStorageRepository())
        let session = SSHSessionProfile(name: "prod", host: "example.com", username: "ops")
        viewModel.sessions = [session]

        viewModel.openTerminal(sessionID: session.id)
        viewModel.openTerminal(sessionID: session.id)

        XCTAssertEqual(viewModel.openTerminalTabs.count, 2)
        XCTAssertEqual(viewModel.openTerminalTabs.map(\.title), ["prod", "prod"])
        XCTAssertEqual(viewModel.openTerminalTabs.last?.id, viewModel.activeTerminalTabID)
        XCTAssertEqual(viewModel.selectedSessionID, session.id)
    }

    func testMainWindowCloseKeepsTerminalTabsWhenPreferenceIsEnabled() {
        let originalValue = ShellXPreferences.reopenTerminalTabsAfterMainWindowClose
        defer {
            ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = originalValue
        }

        ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = true
        let viewModel = AppViewModel(repository: AppStorageRepository())
        viewModel.openLocalTerminal()

        viewModel.handleMainWindowClosed()

        XCTAssertEqual(viewModel.openTerminalTabs.count, 1)
        XCTAssertEqual(viewModel.activeTerminalTabID, AppViewModel.localTerminalID)
    }

    func testLoadRestoresTabsSavedWhenMainWindowClosed() async {
        let originalValue = ShellXPreferences.reopenTerminalTabsAfterMainWindowClose
        let suiteName = "ShellXTests.TabRestoration.\(UUID().uuidString)"
        let snapshotStore = UserDefaults(suiteName: suiteName)!
        defer {
            ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = originalValue
            snapshotStore.removePersistentDomain(forName: suiteName)
        }

        ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = true
        let sourceViewModel = AppViewModel(
            repository: AppStorageRepository(),
            terminalTabsSnapshotStore: snapshotStore
        )
        sourceViewModel.openLocalTerminal()
        sourceViewModel.duplicateTerminal(tabID: AppViewModel.localTerminalID)
        let activeTabID = sourceViewModel.activeTerminalTabID

        sourceViewModel.handleMainWindowClosed()

        let restoredViewModel = AppViewModel(
            repository: AppStorageRepository(),
            terminalTabsSnapshotStore: snapshotStore
        )
        await restoredViewModel.load()

        XCTAssertEqual(restoredViewModel.openTerminalTabs.count, 2)
        XCTAssertEqual(restoredViewModel.activeTerminalTabID, activeTabID)
        XCTAssertEqual(restoredViewModel.openTerminalTabs.map(\.title), ["本机终端", "本机终端"])
    }

    func testMainWindowCloseClearsTerminalTabsWhenPreferenceIsDisabled() {
        let originalValue = ShellXPreferences.reopenTerminalTabsAfterMainWindowClose
        defer {
            ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = originalValue
        }

        ShellXPreferences.reopenTerminalTabsAfterMainWindowClose = false
        let viewModel = AppViewModel(repository: AppStorageRepository())
        viewModel.openLocalTerminal()

        viewModel.handleMainWindowClosed()

        XCTAssertTrue(viewModel.openTerminalTabs.isEmpty)
        XCTAssertNil(viewModel.activeTerminalTabID)
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

    func testPreferredZModemDirectionRecognizesTmuxWrappedSzCommand() {
        let direction = SSHPTYTransport.preferredZModemDirection(
            from: "tmux split-window -h 'sz logs.tar.gz'"
        )

        XCTAssertEqual(direction, .downloadFromRemote)
    }

    func testPreferredZModemDirectionRecognizesNestedShellWrappedRzCommand() {
        let direction = SSHPTYTransport.preferredZModemDirection(
            from: "bash -lc \"exec rz --escape\""
        )

        XCTAssertEqual(direction, .uploadToRemote)
    }

    func testZModemProgressParserExtractsCurrentFileAndPercent() {
        var parser = ZModemProgressParser(direction: .uploadToRemote, totalFiles: 2)

        let progress = parser.consume(
            Data("Sending: report.log\rreport.log 45% 450 KB/1 MB 120 KB/s 00:04 ETA\r".utf8)
        )

        XCTAssertEqual(progress?.currentFileName, "report.log")
        XCTAssertEqual(progress?.percent, 45)
        XCTAssertEqual(progress?.totalFiles, 2)
        XCTAssertEqual(progress?.completedFiles, 0)
    }

    func testZModemProgressParserExtractsLrzszByteProgress() {
        var parser = ZModemProgressParser(direction: .uploadToRemote)

        _ = parser.consume(Data("Sending demo.iso, 1024 blocks:\r".utf8))
        let progress = parser.consume(
            Data("Bytes Sent:   524288/ 1048576   BPS:262144   ETA 00:02  \r".utf8)
        )

        XCTAssertEqual(progress?.currentFileName, "demo.iso")
        XCTAssertEqual(progress?.percent, 50)
        XCTAssertEqual(progress?.byteSummary, "512KB/1.0MB")
        XCTAssertEqual(progress?.speed, "256KB/s")
        XCTAssertEqual(progress?.eta, "00:02")
    }

    func testZModemProgressParserTracksMultipleFiles() {
        var parser = ZModemProgressParser(direction: .downloadFromRemote)

        _ = parser.consume(Data("Receiving: first.txt\r".utf8))
        let progress = parser.consume(Data("Receiving: second.txt\r".utf8))

        XCTAssertEqual(progress?.currentFileName, "second.txt")
        XCTAssertEqual(progress?.completedFiles, 1)
        XCTAssertEqual(progress?.totalFiles, 2)
    }

    func testSFTPProgressParserExtractsProgressAndSpeed() {
        var parser = SFTPProgressParser(direction: .download)

        let progress = parser.consume(
            Data("archive.tar.gz                               42% 2048KB 12.5MB/s 00:03 ETA\r".utf8)
        )

        XCTAssertEqual(progress?.currentFileName, "archive.tar.gz")
        XCTAssertEqual(progress?.percent, 42)
        XCTAssertEqual(progress?.byteSummary, "2048KB")
        XCTAssertEqual(progress?.speed, "12.5MB/s")
        XCTAssertEqual(progress?.eta, "00:03")
    }

    func testSFTPProgressParserTracksMultipleFiles() {
        var parser = SFTPProgressParser(direction: .upload)

        _ = parser.consume(Data("first.log                                     100% 512KB 8.0MB/s 00:00 ETA\r".utf8))
        let progress = parser.consume(Data("second.log                                    5% 64KB 1.0MB/s 00:07 ETA\r".utf8))

        XCTAssertEqual(progress?.currentFileName, "second.log")
        XCTAssertEqual(progress?.completedFiles, 1)
        XCTAssertEqual(progress?.totalFiles, 2)
    }

    func testZModemTransferArgumentsDoNotForceSmallBuffer() {
        let uploadArguments = SSHPTYTransport.zmodemUploadArguments(for: ["/tmp/demo.iso"])
        let downloadArguments = SSHPTYTransport.zmodemDownloadArguments()

        XCTAssertFalse(uploadArguments.contains("--bufsize"))
        XCTAssertFalse(downloadArguments.contains("--bufsize"))
        XCTAssertEqual(
            uploadArguments,
            ["--escape", "--binary", "--verbose", "--verbose", "/tmp/demo.iso"]
        )
        XCTAssertEqual(downloadArguments, ["--rename", "--escape", "--binary", "--verbose", "--verbose"])
    }

    func testKeyboardCancelClearsActiveZModemTransferState() {
        let viewModel = TerminalSessionViewModel()
        viewModel.transferState = .transferring(ZModemTransferProgress(direction: .uploadToRemote))

        XCTAssertTrue(viewModel.cancelActiveTransferFromKeyboard())

        XCTAssertEqual(viewModel.transferState, .failed("已取消 lrzsz 传输"))
    }

    func testKeyboardCancelClearsActiveSFTPTransferState() {
        let viewModel = TerminalSessionViewModel()
        viewModel.transferState = .sftpTransferring(SFTPTransferProgress(direction: .download))

        XCTAssertTrue(viewModel.cancelActiveTransferFromKeyboard())

        XCTAssertEqual(viewModel.transferState, .failed("已取消 SFTP 传输"))
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
