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
    @State private var passwordDraft = ""
    @State private var tagDraft = ""
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
                TextField("用户名", text: $draft.username)
                TextField("端口", text: portTextBinding)

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
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("将密码保存到系统 Keychain", isOn: $draft.passwordStoredInKeychain)

                        if draft.passwordStoredInKeychain {
                            SecureField("重新设置登录密码", text: $passwordDraft)
                                .textFieldStyle(.roundedBorder)

                            Text(passwordHelpText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(passwordHelpText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("所属文件夹", selection: $draft.folderID) {
                    Text("未分组").tag(Optional<UUID>.none)
                    ForEach(appModel.folders.sorted(by: { $0.name < $1.name })) { folder in
                        Text("\(String(repeating: "  ", count: appModel.indentationLevel(for: folder.id)))\(folder.name)")
                            .tag(Optional(folder.id))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("标签")
                        .font(.subheadline)

                    HStack(spacing: 8) {
                        TextField("输入标签后回车或点击添加", text: $tagDraft)
                            .onSubmit {
                                appendTagFromDraft()
                            }
                        Button("添加") {
                            appendTagFromDraft()
                        }
                        .disabled(tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if draft.tags.isEmpty {
                        Text("尚未添加标签")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        SessionTagWrapView(tags: draft.tags) { tag in
                            removeTag(tag)
                        }
                    }

                    Text("标签会显示在会话详情和终端底部栏，用于快速识别环境、角色或用途。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TextField("连接后执行命令", text: $draft.startupCommand, axis: .vertical)
                    .lineLimit(2...4)
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
                    }

                    onSave(
                        SessionEditorSubmission(
                            session: session,
                            password: passwordDraft
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

    private var canSave: Bool {
        draft.isValid
    }

    private var portTextBinding: Binding<String> {
        Binding(
            get: {
                draft.port > 0 ? String(draft.port) : ""
            },
            set: { newValue in
                // 端口输入应保持纯数字文本，避免受本地化数值格式影响出现千分位分隔符。
                let digitsOnly = newValue.filter(\.isNumber)
                guard !digitsOnly.isEmpty else {
                    draft.port = 0
                    return
                }

                if let port = Int(digitsOnly) {
                    draft.port = port
                }
            }
        )
    }

    private var passwordHelpText: String {
        if draft.passwordStoredInKeychain {
            return "在这里输入新密码并保存，会立即新建或刷新系统 Keychain 条目；留空保存则保持当前已保存密码不变。后续 SSH 和 SFTP 在真正需要密码时都会优先复用。"
        }
        return "关闭后，SSH 和 SFTP 在需要密码时都会提示你手动输入一次；密码不会写入 ShellX 的 sessions.json。"
    }

    private func appendTagFromDraft() {
        let trimmedTag = tagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return }
        if !draft.tags.contains(trimmedTag) {
            draft.tags.append(trimmedTag)
        }
        tagDraft = ""
    }

    private func removeTag(_ tag: String) {
        draft.tags.removeAll { $0 == tag }
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

private struct SessionTagWrapView: View {
    let tags: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 6) {
                    Text(tag)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        onRemove(tag)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
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
