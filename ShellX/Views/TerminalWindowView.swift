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
        sessionModel.reconnect(session: session) {
            appModel.markConnected(sessionID: session.id)
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
            Text("确认主机指纹")
                .font(.title2.weight(.semibold))

            Text("目标：\(prompt.host):\(prompt.port)")
                .foregroundStyle(.secondary)

            Text("这是该主机的首次连接，请确认以下指纹是否可信：")

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(prompt.newFingerprints, id: \.self) { fingerprint in
                        Text(fingerprint)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            .frame(height: 160)

            Text("确认后，ShellX 会将该主机公钥写入应用自己的 known_hosts 文件，并在后续连接中强制校验。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    onCancel()
                    dismiss()
                }
                Button("信任并继续") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 360)
    }
}
