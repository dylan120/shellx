import AppKit
import SwiftUI

struct TerminalWindowContainerView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let sessionID: String?

    var body: some View {
        if let sessionID,
           let uuid = UUID(uuidString: sessionID),
           let session = appModel.sessions.first(where: { $0.id == uuid }) {
            TerminalWindowView(
                sessionModel: appModel.terminalSessionModel(for: session.id),
                session: session,
                localShellPath: nil,
                localShellLaunchMode: .login,
                onCloseCurrentTab: {},
                allowsModalPresentation: true
            )
        } else {
            ContentUnavailableView(
                "无法打开会话",
                systemImage: "exclamationmark.triangle",
                description: Text("没有找到对应的 SSH 会话配置。")
            )
        }
    }
}

struct TerminalWindowView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @ObservedObject var sessionModel: TerminalSessionViewModel
    @State private var showingErrorDetails = false
    @State private var isPresentingZModemPanel = false

    let session: SSHSessionProfile?
    let localShellPath: String?
    let localShellLaunchMode: LocalShellLaunchMode
    let onCloseCurrentTab: () -> Void
    let allowsModalPresentation: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                SwiftTermTerminalView(sessionModel: sessionModel, isActive: allowsModalPresentation)
                    .background(Color(nsColor: .textBackgroundColor))
                    .contextMenu {
                        Button("复制") {
                            sessionModel.copySelectedText()
                        }
                        .disabled(!sessionModel.hasTextSelection)

                        Button("粘贴") {
                            sessionModel.pasteClipboardText()
                        }

                        Divider()

                        Button("关闭") {
                            onCloseCurrentTab()
                        }
                    }

                if let banner = sessionModel.bannerContent {
                    ErrorBannerView(message: banner.message, isError: banner.isError)
                        .padding(12)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            HStack(spacing: 12) {
                Label(sessionModel.terminalTitle, systemImage: "terminal")
                    .font(.subheadline.weight(.medium))
                if let session {
                    HStack(spacing: 6) {
                        Text("\(session.destination):\(session.port)")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        Button {
                            sessionModel.copyConnectionHost(session.host)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("复制当前连接地址")
                    }
                } else if let localShellPath {
                    Text(localShellPath)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if let workingDirectory = sessionModel.workingDirectory, !workingDirectory.isEmpty {
                    Text(workingDirectory)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if let session, !session.tags.isEmpty {
                    SessionTerminalTagStrip(tags: session.tags)
                }
                Spacer()
                if let transferSummary = sessionModel.footerTransferSummary {
                    Text(transferSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(sessionModel.footerTransferIsError ? Color.red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if case .failed = sessionModel.connectionState,
                   let errorMessage = sessionModel.lastExitMessage ?? failureMessage {
                    Button {
                        showingErrorDetails = true
                    } label: {
                        Text(sessionModel.connectionState.displayText)
                            .foregroundStyle(statusColor)
                    }
                    .buttonStyle(.plain)

                    Button("复制错误") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(errorMessage, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                } else {
                    Text(sessionModel.connectionState.displayText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            if allowsModalPresentation, case .idle = sessionModel.connectionState {
                connect()
            }
        }
        .onChange(of: allowsModalPresentation) { _, isActive in
            guard isActive, case .idle = sessionModel.connectionState else { return }
            connect()
        }
        // 终端标签会常驻保活；系统 sheet 只能挂在当前活动标签上，
        // 这里通过稳定的条件绑定限制弹窗宿主，避免切换标签时重建 SwiftTerm 视图导致输出缓冲丢失。
        .sheet(item: activeHostKeyPromptBinding) { prompt in
            HostKeyPromptSheet(
                prompt: prompt,
                onConfirm: {
                    sessionModel.trustCurrentHostAndContinue()
                },
                onCancel: {
                    sessionModel.cancelHostTrust()
                }
            )
        }
        .sheet(item: activePasswordPromptBinding) { prompt in
            SSHPasswordPromptSheet(
                prompt: prompt,
                onConfirm: { password in
                    sessionModel.submitPasswordAndContinue(password)
                },
                onCancel: {
                    sessionModel.cancelPasswordPrompt()
                }
            )
        }
        .sheet(item: activeSFTPPathPromptBinding) { prompt in
            SFTPPathPromptSheet(
                prompt: prompt,
                onConfirm: { path in
                    sessionModel.handleSFTPPathPromptConfirm(prompt, path: path)
                },
                onCancel: {
                    sessionModel.handleSFTPPathPromptCancel()
                }
            )
        }
        .onChange(of: sessionModel.zmodemSelectionRequest) { _, request in
            guard allowsModalPresentation, let request else { return }
            presentZModemSelection(request)
        }
        .onChange(of: sessionModel.sftpLocalSelectionRequest) { _, request in
            guard allowsModalPresentation, let request else { return }
            presentSFTPLocalSelection(request)
        }
        .sheet(isPresented: activeErrorDetailsBinding) {
            ErrorDetailSheet(message: sessionModel.lastExitMessage ?? failureMessage ?? "未知错误")
        }
    }

    private var statusColor: Color {
        switch sessionModel.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .disconnected, .idle:
            return .secondary
        }
    }

    private func connect() {
        if let session {
            sessionModel.reconnect(session: session) { sessionID in
                appModel.markConnected(sessionID: sessionID)
            }
        } else {
            sessionModel.startLocalShell(
                shellPath: localShellPath ?? AppViewModel.defaultLocalShellPath,
                launchMode: localShellLaunchMode
            )
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = sessionModel.connectionState {
            return message
        }
        return nil
    }

    private var activeHostKeyPromptBinding: Binding<KnownHostPrompt?> {
        Binding(
            get: { allowsModalPresentation ? sessionModel.hostKeyPrompt : nil },
            set: {
                guard allowsModalPresentation else { return }
                sessionModel.hostKeyPrompt = $0
            }
        )
    }

    private var activePasswordPromptBinding: Binding<SSHPasswordPrompt?> {
        Binding(
            get: { allowsModalPresentation ? sessionModel.passwordPrompt : nil },
            set: {
                guard allowsModalPresentation else { return }
                sessionModel.passwordPrompt = $0
            }
        )
    }

    private var activeSFTPPathPromptBinding: Binding<SFTPPathPrompt?> {
        Binding(
            get: { allowsModalPresentation ? sessionModel.sftpPathPrompt : nil },
            set: {
                guard allowsModalPresentation else { return }
                sessionModel.sftpPathPrompt = $0
            }
        )
    }

    private var activeErrorDetailsBinding: Binding<Bool> {
        Binding(
            get: { allowsModalPresentation && showingErrorDetails },
            set: {
                guard allowsModalPresentation else { return }
                showingErrorDetails = $0
            }
        )
    }

    @MainActor
    private func presentZModemSelection(_ request: ZModemSelectionRequest) {
        guard !isPresentingZModemPanel else { return }
        isPresentingZModemPanel = true
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = request == .upload
        panel.canCreateDirectories = request == .download
        panel.canChooseFiles = request == .upload
        panel.canChooseDirectories = request == .download
        panel.resolvesAliases = true
        panel.message = request == .upload ? "选择要上传到远端的本地文件，可多选" : "选择接收远端文件的本地目录"
        panel.prompt = request == .upload ? "上传" : "选择目录"

        let handleResult: (NSApplication.ModalResponse) -> Void = { response in
            isPresentingZModemPanel = false
            if response == .OK {
                switch request {
                case .upload:
                    sessionModel.handleUploadSelection(.success(panel.urls))
                case .download:
                    guard let url = panel.url else {
                        sessionModel.handleDownloadSelection(.failure(CocoaError(.fileNoSuchFile)))
                        return
                    }
                    sessionModel.handleDownloadSelection(.success(url))
                }
            } else {
                switch request {
                case .upload:
                    sessionModel.handleUploadSelection(.failure(CocoaError(.userCancelled)))
                case .download:
                    sessionModel.handleDownloadSelection(.failure(CocoaError(.userCancelled)))
                }
            }
        }

        DispatchQueue.main.async {
            // 统一走独立模态窗口，避免主窗口标签页、SwiftUI 和 SwiftTerm 共同参与事件分发时
            // 出现“面板显示出来但无法点击”的焦点链异常。
            handleResult(panel.runModal())
        }
    }

    @MainActor
    private func presentSFTPLocalSelection(_ request: SFTPLocalSelectionRequest) {
        guard !isPresentingZModemPanel else { return }
        isPresentingZModemPanel = true
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        switch request {
        case .uploadSource:
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.message = "选择要通过 SFTP 上传的本地文件或文件夹"
            panel.prompt = "选择"
        case .downloadDestination:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.message = "选择通过 SFTP 下载后的本地保存目录"
            panel.prompt = "选择目录"
        }

        let handleResult: (NSApplication.ModalResponse) -> Void = { response in
            isPresentingZModemPanel = false
            if response == .OK, let url = panel.url {
                sessionModel.handleSFTPLocalSelection(.success(url))
            } else {
                sessionModel.handleSFTPLocalSelection(.failure(CocoaError(.userCancelled)))
            }
        }

        DispatchQueue.main.async {
            handleResult(panel.runModal())
        }
    }
}

private struct SessionTerminalTagStrip: View {
    @Environment(\.colorScheme) private var colorScheme
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(tagForegroundColor)
                        .background(tagBackgroundColor, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(tagBorderColor, lineWidth: 1)
                        }
                }
            }
        }
        .frame(maxWidth: 280)
    }

    private var tagForegroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : .primary
    }

    private var tagBackgroundColor: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.26 : 0.12)
    }

    private var tagBorderColor: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.42 : 0.22)
    }
}

private struct ErrorBannerView: View {
    let message: String
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button(isError ? "复制错误" : "复制内容") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ErrorDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("错误详情")
                .font(.title2.weight(.semibold))

            ScrollView {
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding()
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button("复制错误") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 320)
    }
}

private struct SSHPasswordPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""

    let prompt: SSHPasswordPrompt
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("输入 SSH 密码")
                .font(.title2.weight(.semibold))

            Text("会话：\(prompt.sessionName)")
                .foregroundStyle(.secondary)

            Text(prompt.message)

            SecureField("本次连接密码", text: $password)

            Text("本次输入的密码仅用于当前连接，不会写入 ShellX 的本地配置文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Button("继续连接") {
                    onConfirm(password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct SFTPPathPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var path = ""

    let prompt: SFTPPathPrompt
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title)
                .font(.title2.weight(.semibold))

            Text("会话：\(prompt.sessionName)")
                .foregroundStyle(.secondary)

            Text(prompt.message)

            TextField("远端路径", text: $path)
                .textFieldStyle(.roundedBorder)

            Text("留空时默认使用当前远端目录。下载文件夹时会使用递归传输。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Button("继续") {
                    onConfirm(path.isEmpty ? prompt.defaultPath : path)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            path = prompt.defaultPath
        }
    }
}

private struct HostKeyPromptSheet: View {
    @Environment(\.dismiss) private var dismiss

    let prompt: KnownHostPrompt
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titleText)
                .font(.title2.weight(.semibold))

            Text("目标：\(prompt.host):\(prompt.port)")
                .foregroundStyle(.secondary)

            Text(summaryText)

            if prompt.kind != .unknown {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前已记录的旧指纹：")
                        .font(.headline)
                    fingerprintList(prompt.existingFingerprints)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(prompt.kind == .unknown ? "本次扫描到的指纹：" : "本次扫描到的新指纹：")
                    .font(.headline)
                fingerprintList(prompt.newFingerprints)
            }

            Text(footerText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Button(confirmButtonText) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }

    private var summaryText: String {
        switch prompt.kind {
        case .unknown:
            return "这是该主机的首次连接，请确认以下指纹是否可信："
        case .updated:
            return "检测到该主机当前公布的指纹集合与本地记录不完全一致。常见原因是服务器新增或调整了 host key 算法。请带外确认后，再决定是否更新本地 known_hosts："
        case .changed:
            return "检测到该主机指纹与本地记录不一致。这可能是主机重装、密钥轮换，也可能是中间人攻击。请先带外确认后，再决定是否替换："
        }
    }

    private var footerText: String {
        switch prompt.kind {
        case .unknown:
            return "确认后，ShellX 会将该主机公钥写入应用自己的 known_hosts 文件，并在后续连接中强制校验。"
        case .updated:
            return "确认更新后，ShellX 会刷新该主机在应用内 known_hosts 里的记录，补齐当前可用的 host key。"
        case .changed:
            return "确认替换后，ShellX 会先移除该主机的旧指纹，再写入新指纹并继续连接。"
        }
    }

    private var titleText: String {
        switch prompt.kind {
        case .unknown:
            return "确认主机指纹"
        case .updated:
            return "确认并更新主机指纹"
        case .changed:
            return "确认并替换主机指纹"
        }
    }

    private var confirmButtonText: String {
        switch prompt.kind {
        case .unknown:
            return "信任并继续"
        case .updated:
            return "更新并继续"
        case .changed:
            return "替换并继续"
        }
    }

    @ViewBuilder
    private func fingerprintList(_ fingerprints: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fingerprints, id: \.self) { fingerprint in
                    Text(fingerprint)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(height: 120)
    }
}
