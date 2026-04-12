import SwiftUI

struct SessionManagerView: View {
    enum ActiveSheet: Identifiable {
        case createSession
        case editSession(SSHSessionProfile)
        case createFolder(SessionFolder?)
        case editFolder(SessionFolder)

        var id: String {
            switch self {
            case .createSession:
                return "createSession"
            case .editSession(let session):
                return "editSession-\(session.id.uuidString)"
            case .createFolder(let parent):
                return "createFolder-\(parent?.id.uuidString ?? "root")"
            case .editFolder(let folder):
                return "editFolder-\(folder.id.uuidString)"
            }
        }
    }

    @EnvironmentObject private var appModel: AppViewModel
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        NavigationSplitView {
            SidebarTreeView(
                onAddSubfolder: { parent in
                    activeSheet = .createFolder(parent)
                },
                onRenameFolder: { folder in
                    activeSheet = .editFolder(folder)
                },
                onDeleteFolder: { folder in
                    appModel.deleteFolder(folder)
                }
            )
        } content: {
            VStack(spacing: 0) {
                HStack {
                    TextField("搜索会话名称 / 主机 / 用户", text: $appModel.searchText)
                        .textFieldStyle(.roundedBorder)
                    Text("共 \(appModel.filteredSessions.count) 项")
                        .foregroundStyle(.secondary)
                }
                .padding()

                List(selection: $appModel.selectedSessionID) {
                    ForEach(appModel.filteredSessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.name)
                                .font(.headline)
                            Text("\(session.destination):\(session.port)")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .tag(Optional(session.id))
                        .onTapGesture {
                            appModel.selectedSessionID = session.id
                        }
                        .onTapGesture(count: 2) {
                            appModel.selectedSessionID = session.id
                            openTerminal(for: session)
                        }
                        .contextMenu {
                            Button("连接") {
                                openTerminal(for: session)
                            }
                            Button("复制") {
                                appModel.duplicateSession(session)
                            }
                            Button("编辑") {
                                activeSheet = .editSession(session)
                            }
                            Divider()
                            Button("删除", role: .destructive) {
                                appModel.deleteSession(session)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        } detail: {
            if appModel.openTerminalSessions.isEmpty {
                SessionDetailView(
                    onEdit: { session in
                        activeSheet = .editSession(session)
                    },
                    onConnect: openTerminal(for:)
                )
            } else {
                TerminalTabWorkspaceView(
                    onEdit: { session in
                        activeSheet = .editSession(session)
                    },
                    onClose: { sessionID in
                        appModel.closeTerminal(sessionID: sessionID)
                    }
                )
            }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .navigationTitle("ShellX")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    activeSheet = .createFolder(currentFolderParent)
                } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }

                Button {
                    activeSheet = .createSession
                } label: {
                    Label("新建会话", systemImage: "plus")
                }

                Button {
                    if let session = appModel.selectedSession {
                        openTerminal(for: session)
                    }
                } label: {
                    Label("连接", systemImage: "play.circle")
                }
                .disabled(appModel.selectedSession == nil)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .createSession:
                SessionEditorSheet(
                    session: SSHSessionProfile(folderID: appModel.selectedFolderID),
                    title: "新建 SSH 会话",
                    onSave: saveSessionSubmission
                )
            case .editSession(let session):
                SessionEditorSheet(
                    session: session,
                    title: "编辑 SSH 会话",
                    onSave: saveSessionSubmission
                )
            case .createFolder(let parent):
                FolderEditorSheet(
                    folder: SessionFolder(parentID: parent?.id, name: ""),
                    title: parent == nil ? "新建文件夹" : "新建子文件夹",
                    onSave: appModel.saveFolder
                )
            case .editFolder(let folder):
                FolderEditorSheet(
                    folder: folder,
                    title: "重命名文件夹",
                    onSave: appModel.saveFolder
                )
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { visible in
                    if !visible {
                        appModel.dismissError()
                    }
                }
            ),
            actions: {
                Button("确定", role: .cancel) {
                    appModel.dismissError()
                }
            },
            message: {
                Text(appModel.errorMessage ?? "")
            }
        )
        .onChange(of: appModel.searchText) { _, _ in
            appModel.syncSelectionToVisibleSessions()
        }
        .onChange(of: appModel.selectedFolderID) { _, _ in
            appModel.syncSelectionToVisibleSessions()
        }
    }

    private var currentFolderParent: SessionFolder? {
        guard let folderID = appModel.selectedFolderID else { return nil }
        return appModel.folders.first(where: { $0.id == folderID })
    }

    private func openTerminal(for session: SSHSessionProfile) {
        appModel.openTerminal(sessionID: session.id)
    }

    private func saveSessionSubmission(_ submission: SessionEditorSubmission) {
        appModel.saveSession(submission)
    }
}

private struct TerminalTabWorkspaceView: View {
    @EnvironmentObject private var appModel: AppViewModel

    let onEdit: (SSHSessionProfile) -> Void
    let onClose: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appModel.openTerminalSessions) { session in
                        HStack(spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "terminal")
                                Text(session.name)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appModel.activeTerminalSessionID = session.id
                                appModel.selectedSessionID = session.id
                            }

                            Button {
                                onClose(session.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.bold())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(tabBackground(for: session.id), in: Capsule())
                    }
                    if let activeSession = activeSession {
                        Button("编辑当前会话") {
                            onEdit(activeSession)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.thinMaterial)

            if let activeSession {
                TerminalWindowView(
                    sessionModel: appModel.terminalSessionModel(for: activeSession.id),
                    session: activeSession
                )
                .id(activeSession.id)
                .overlay(alignment: .topTrailing) {
                    if let selectedSession = appModel.selectedSession,
                       selectedSession.id != appModel.activeTerminalSessionID {
                        Text("当前左侧选中：\(selectedSession.name)")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .padding(12)
                    }
                }
            } else {
                ContentUnavailableView(
                    "没有打开的终端标签",
                    systemImage: "terminal",
                    description: Text("从会话列表或详情面板中点击“连接”后，会在这里以标签页形式显示。")
                )
            }
        }
    }

    private var activeSession: SSHSessionProfile? {
        if let activeID = appModel.activeTerminalSessionID {
            return appModel.sessions.first(where: { $0.id == activeID })
        }
        return appModel.openTerminalSessions.first
    }

    private func tabBackground(for sessionID: UUID) -> some ShapeStyle {
        sessionID == appModel.activeTerminalSessionID ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear)
    }
}

private struct SessionDetailView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let onEdit: (SSHSessionProfile) -> Void
    let onConnect: (SSHSessionProfile) -> Void

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        if let session = appModel.selectedSession {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.name)
                        .font(.largeTitle.weight(.bold))

                    LabeledContent("主机", value: session.host)
                    LabeledContent("端口", value: "\(session.port)")
                    LabeledContent("用户名", value: session.username.isEmpty ? "未填写" : session.username)
                    LabeledContent("认证方式", value: session.authMethod.displayName)
                    LabeledContent("所属文件夹", value: appModel.folderName(for: session.folderID))

                    if !session.privateKeyPath.isEmpty {
                        LabeledContent("私钥路径", value: session.privateKeyPath)
                        LabeledContent("Keychain", value: session.useKeychainForPrivateKey ? "已启用" : "未启用")
                    }

                    if session.authMethod == .password {
                        LabeledContent("密码存储", value: session.passwordStoredInKeychain ? "系统 Keychain" : "未保存")
                    }

                    if !session.startupCommand.isEmpty {
                        LabeledContent("启动命令", value: session.startupCommand)
                    }

                    if !session.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("备注")
                                .font(.headline)
                            Text(session.notes)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent(
                        "最近连接",
                        value: session.lastConnectedAt.map { formatter.string(from: $0) } ?? "暂无"
                    )

                    HStack {
                        Button("编辑") {
                            onEdit(session)
                        }
                        Button("连接") {
                            onConnect(session)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        } else {
            ContentUnavailableView(
                "选择一个会话",
                systemImage: "terminal",
                description: Text("从左侧文件夹树或会话列表中选择要管理的 SSH 会话。")
            )
        }
    }
}
