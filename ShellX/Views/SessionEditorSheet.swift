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
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text("配置 SSH 目标、认证方式和连接后的启动行为。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: ShellXUI.sectionSpacing) {
                    ShellXSection("基础信息", subtitle: "名称、主机和端口会用于会话列表与连接命令。") {
                        formTextField("会话名称", text: $draft.name)
                        formTextField("主机地址", text: $draft.host)
                        formTextField("用户名", text: $draft.username)
                        formTextField("端口", text: portTextBinding)
                        validationText("端口范围为 1-65535。", isVisible: draft.port != 0 && !(1...65535).contains(draft.port))
                    }

                    ShellXSection("认证") {
                        Picker("认证方式", selection: $draft.authMethod) {
                            ForEach(SSHAuthMethod.allCases) { method in
                                Text(method.displayName).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)

                        if draft.authMethod == .privateKey {
                            privateKeyPicker
                            Toggle("将私钥口令交给系统 Keychain 管理", isOn: $draft.useKeychainForPrivateKey)
                        }

                        if draft.authMethod == .password {
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle("将密码保存到系统 Keychain", isOn: $draft.passwordStoredInKeychain)

                                if draft.passwordStoredInKeychain {
                                    SecureField("重新设置登录密码", text: $passwordDraft)
                                        .textFieldStyle(.roundedBorder)
                                }

                                Text(passwordHelpText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ShellXSection("组织") {
                        Picker("所属文件夹", selection: $draft.folderID) {
                            Text("未分组").tag(Optional<UUID>.none)
                            ForEach(appModel.folders.sorted(by: { $0.name < $1.name })) { folder in
                                Text("\(String(repeating: "  ", count: appModel.indentationLevel(for: folder.id)))\(folder.name)")
                                    .tag(Optional(folder.id))
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("输入标签后回车或点击添加", text: $tagDraft)
                                    .onSubmit {
                                        appendTagFromDraft()
                                    }
                                Button {
                                    appendTagFromDraft()
                                } label: {
                                    Label("添加", systemImage: "plus")
                                }
                                .buttonStyle(.bordered)
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
                    }

                    ShellXSection("启动行为") {
                        TextField("连接后执行命令", text: $draft.startupCommand, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                        Text("命令会在 SSH 连接建立后写入终端，适合进入目录或初始化环境。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    appendTagFromDraft()
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
        .frame(minWidth: 600, minHeight: 620)
    }

    private var canSave: Bool {
        draft.isValid
    }

    private var validationMessage: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写会话名称。"
        }
        if draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请填写主机地址。"
        }
        if !(1...65535).contains(draft.port) {
            return "请填写有效端口。"
        }
        if draft.authMethod == .privateKey && draft.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请选择私钥文件。"
        }
        if draft.authMethod == .password && draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "账号密码认证需要填写用户名。"
        }
        return nil
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

    private var privateKeyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text(draft.privateKeyPath.isEmpty ? "尚未选择私钥文件" : draft.privateKeyPath)
                    .foregroundStyle(draft.privateKeyPath.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

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
            .padding(10)
            .background(ShellXUI.subtleBackground, in: RoundedRectangle(cornerRadius: ShellXUI.controlCornerRadius))

            Text("请选择本机上的私钥文件，ShellX 会使用该文件路径调用系统 ssh。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let privateKeySelectionError {
                Text(privateKeySelectionError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func formTextField(_ title: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func validationText(_ message: String, isVisible: Bool) -> some View {
        if isVisible {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    static func tagsByAppendingDraft(_ draftTag: String, to tags: [String]) -> (tags: [String], draftTag: String) {
        let trimmedTag = draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else {
            return (tags, draftTag)
        }

        var updatedTags = tags
        if !updatedTags.contains(trimmedTag) {
            updatedTags.append(trimmedTag)
        }
        return (updatedTags, "")
    }

    private func appendTagFromDraft() {
        let updated = Self.tagsByAppendingDraft(tagDraft, to: draft.tags)
        draft.tags = updated.tags
        tagDraft = updated.draftTag
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
                    ShellXTagChip(title: tag) {
                        onRemove(tag)
                    }
                }
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
