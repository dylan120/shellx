import AppKit
import SwiftUI

struct TerminalWindowContainerView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let sessionID: String?

    var body: some View {
        if let sessionID,
           let uuid = UUID(uuidString: sessionID),
           let session = appModel.sessions.first(where: { $0.id == uuid }) {
            TerminalWindowView(session: session)
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
    @StateObject private var sessionModel = TerminalSessionViewModel()

    let session: SSHSessionProfile

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(sessionModel.terminalTitle, systemImage: "terminal")
                    .font(.headline)
                Text("\(session.destination):\(session.port)")
                    .foregroundStyle(.secondary)
                if let workingDirectory = sessionModel.workingDirectory, !workingDirectory.isEmpty {
                    Text(workingDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(sessionModel.connectionState.displayText)
                    .foregroundStyle(statusColor)
                Button("重连") {
                    connect()
                }
                Button("断开") {
                    sessionModel.terminate()
                }
            }
            .padding()
            .background(.thinMaterial)

            ZStack(alignment: .bottomLeading) {
                SwiftTermTerminalView(sessionModel: sessionModel)
                    .background(Color(nsColor: .textBackgroundColor))

                if let bannerText = sessionModel.transferState.bannerText ?? sessionModel.lastExitMessage,
                   sessionModel.connectionState != .connected || sessionModel.transferState != .idle {
                    Text(bannerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            if case .idle = sessionModel.connectionState {
                connect()
            }
        }
        .onDisappear {
            sessionModel.terminate()
        }
        .sheet(item: $sessionModel.hostKeyPrompt) { prompt in
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
        sessionModel.reconnect(session: session) { sessionID in
            appModel.markConnected(sessionID: sessionID)
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
            Text(prompt.kind == .changed ? "确认并替换主机指纹" : "确认主机指纹")
                .font(.title2.weight(.semibold))

            Text("目标：\(prompt.host):\(prompt.port)")
                .foregroundStyle(.secondary)

            Text(summaryText)

            if prompt.kind == .changed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前已记录的旧指纹：")
                        .font(.headline)
                    fingerprintList(prompt.existingFingerprints)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(prompt.kind == .changed ? "本次扫描到的新指纹：" : "本次扫描到的指纹：")
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
                Button(prompt.kind == .changed ? "替换并继续" : "信任并继续") {
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
        case .changed:
            return "检测到该主机指纹与本地记录不一致。这可能是主机重装、密钥轮换，也可能是中间人攻击。请先带外确认后，再决定是否替换："
        }
    }

    private var footerText: String {
        switch prompt.kind {
        case .unknown:
            return "确认后，ShellX 会将该主机公钥写入应用自己的 known_hosts 文件，并在后续连接中强制校验。"
        case .changed:
            return "确认替换后，ShellX 会先移除该主机的旧指纹，再写入新指纹并继续连接。"
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
