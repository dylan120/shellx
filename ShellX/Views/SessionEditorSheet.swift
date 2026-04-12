import SwiftUI

struct SessionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel

    @State private var draft: SSHSessionProfile
    let title: String
    let onSave: (SSHSessionProfile) -> Void

    init(session: SSHSessionProfile, title: String, onSave: @escaping (SSHSessionProfile) -> Void) {
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
                    TextField("私钥路径", text: $draft.privateKeyPath)
                    Toggle("将私钥口令交给系统 Keychain 管理", isOn: $draft.useKeychainForPrivateKey)
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
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
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
