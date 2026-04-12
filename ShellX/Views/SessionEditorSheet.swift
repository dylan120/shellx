import AppKit
import SwiftUI

struct SessionEditorSubmission {
    let session: SSHSessionProfile
    let password: String
}

struct SessionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel

    @State private var draft: SSHSessionProfile
    @State private var password = ""
    @State private var privateKeySelectionError: String?
    let title: String
    let onSave: (SessionEditorSubmission) -> Void

    init(session: SSHSessionProfile, title: String, onSave: @escaping (SessionEditorSubmission) -> Void) {
        self._draft = State(initialValue: session)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))

            Form {
                TextField("会话名称", text: $draft.name)
                TextField("主机地址", text: $draft.host)

                HStack {
                    TextField("用户名", text: $draft.username)
                    TextField("端口", value: $draft.port, format: .number)
                        .frame(width: 120)
                }

                Picker("认证方式", selection: $draft.authMethod) {
                    ForEach(SSHAuthMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }

                if draft.authMethod == .privateKey {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("私钥文件")
                            .font(.subheadline)

                        HStack(spacing: 8) {
                            Text(draft.privateKeyPath.isEmpty ? "尚未选择私钥文件" : draft.privateKeyPath)
                                .foregroundStyle(draft.privateKeyPath.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            Button("选择文件") {
                                selectPrivateKeyFile()
                            }

                            if !draft.privateKeyPath.isEmpty {
                                Button("清空") {
                                    draft.privateKeyPath = ""
                                }
                            }
                        }

                        Text("请选择本机上的私钥文件，ShellX 会使用该文件路径调用系统 ssh。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let privateKeySelectionError {
                            Text(privateKeySelectionError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Toggle("将私钥口令交给系统 Keychain 管理", isOn: $draft.useKeychainForPrivateKey)
                }

                if draft.authMethod == .password {
                    Toggle("将密码保存到系统 Keychain", isOn: $draft.passwordStoredInKeychain)
                    SecureField("登录密码", text: $password)
                    Text(passwordHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("所属文件夹", selection: $draft.folderID) {
                    Text("未分组").tag(Optional<UUID>.none)
                    ForEach(appModel.folders.sorted(by: { $0.name < $1.name })) { folder in
                        Text("\(String(repeating: "  ", count: appModel.indentationLevel(for: folder.id)))\(folder.name)")
                            .tag(Optional(folder.id))
                    }
                }

                TextField("连接后执行命令", text: $draft.startupCommand, axis: .vertical)
                    .lineLimit(2...4)

                TextField("备注", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...5)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    var session = draft
                    if session.authMethod != .password {
                        session.passwordStoredInKeychain = false
                    } else if session.passwordStoredInKeychain && !trimmedPassword.isEmpty {
                        session.passwordStoredInKeychain = true
                    }

                    onSave(
                        SessionEditorSubmission(
                            session: session,
                            password: trimmedPassword
                        )
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }

    private var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        draft.isValid
    }

    private var passwordHelpText: String {
        if draft.passwordStoredInKeychain {
            return "密码会尝试保存到系统 Keychain；留空可保持原密码不变。若 Keychain 访问失败，连接时仍可改为手动输入本次密码。"
        }
        return "关闭后不会保存到系统 Keychain。连接时会提示输入本次密码，不会写入 ShellX 的 sessions.json。"
    }

    private func selectPrivateKeyFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.showsHiddenFiles = true
        panel.prompt = "选择"
        panel.message = "选择要用于 SSH 认证的私钥文件"
        if !draft.privateKeyPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (draft.privateKeyPath as NSString).expandingTildeInPath).deletingLastPathComponent()
        }

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return
        }

        guard url.isFileURL else {
            privateKeySelectionError = "选择的私钥路径无效，请重新选择本地文件。"
            return
        }

        privateKeySelectionError = nil
        draft.privateKeyPath = url.path
    }
}

struct FolderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SessionFolder
    let title: String
    let onSave: (SessionFolder) -> Void

    init(folder: SessionFolder, title: String, onSave: @escaping (SessionFolder) -> Void) {
        self._draft = State(initialValue: folder)
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))
            Form {
                TextField("文件夹名称", text: $draft.name)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360, height: 180)
    }
}
