import SwiftUI

struct SidebarTreeView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let onAddSubfolder: (SessionFolder?) -> Void
    let onRenameFolder: (SessionFolder) -> Void
    let onDeleteFolder: (SessionFolder) -> Void
    let onEditSession: (SSHSessionProfile) -> Void
    let onConnectSession: (SSHSessionProfile) -> Void
    let onDuplicateSession: (SSHSessionProfile) -> Void
    let onDeleteSession: (SSHSessionProfile) -> Void

    var body: some View {
        List {
            Section {
                AllSessionsRow()

                ForEach(appModel.rootFolders) { node in
                    FolderBranchView(
                        node: node,
                        onAddSubfolder: onAddSubfolder,
                        onRenameFolder: onRenameFolder,
                        onDeleteFolder: onDeleteFolder,
                        onEditSession: onEditSession,
                        onConnectSession: onConnectSession,
                        onDuplicateSession: onDuplicateSession,
                        onDeleteSession: onDeleteSession
                    )
                }

                ForEach(appModel.rootSessions) { session in
                    SessionTreeRow(
                        session: session,
                        onEditSession: onEditSession,
                        onConnectSession: onConnectSession,
                        onDuplicateSession: onDuplicateSession,
                        onDeleteSession: onDeleteSession
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct AllSessionsRow: View {
    @EnvironmentObject private var appModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            Label("全部会话", systemImage: "tray.full")
            Spacer(minLength: 8)
            Text("\(appModel.filteredSessions.count)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(rowBackground(isSelected: appModel.selectedFolderID == nil))
        .onTapGesture {
            appModel.selectedFolderID = nil
            appModel.syncSelectionToVisibleSessions()
        }
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
    }
}

private struct FolderBranchView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let node: SessionFolderNode
    let onAddSubfolder: (SessionFolder?) -> Void
    let onRenameFolder: (SessionFolder) -> Void
    let onDeleteFolder: (SessionFolder) -> Void
    let onEditSession: (SSHSessionProfile) -> Void
    let onConnectSession: (SSHSessionProfile) -> Void
    let onDuplicateSession: (SSHSessionProfile) -> Void
    let onDeleteSession: (SSHSessionProfile) -> Void

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { appModel.expandedFolderIDs.contains(node.folder.id) },
                set: { isExpanded in
                    if isExpanded {
                        appModel.expandedFolderIDs.insert(node.folder.id)
                    } else {
                        appModel.expandedFolderIDs.remove(node.folder.id)
                    }
                }
            )
        ) {
            ForEach(appModel.sessions(in: node.folder.id)) { session in
                SessionTreeRow(
                    session: session,
                    onEditSession: onEditSession,
                    onConnectSession: onConnectSession,
                    onDuplicateSession: onDuplicateSession,
                    onDeleteSession: onDeleteSession
                )
            }

            ForEach(node.children) { child in
                FolderBranchView(
                    node: child,
                    onAddSubfolder: onAddSubfolder,
                    onRenameFolder: onRenameFolder,
                    onDeleteFolder: onDeleteFolder,
                    onEditSession: onEditSession,
                    onConnectSession: onConnectSession,
                    onDuplicateSession: onDuplicateSession,
                    onDeleteSession: onDeleteSession
                )
            }
        } label: {
            HStack(spacing: 10) {
                Label(node.folder.name, systemImage: "folder")
                Spacer(minLength: 8)
                Text("\(appModel.sessions(in: node.folder.id).count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(rowBackground(isSelected: appModel.selectedFolderID == node.folder.id))
            .onTapGesture {
                appModel.selectedFolderID = node.folder.id
                appModel.syncSelectionToVisibleSessions()
            }
            .contextMenu {
                Button("新建子文件夹") {
                    onAddSubfolder(node.folder)
                }
                Button("重命名") {
                    onRenameFolder(node.folder)
                }
                Divider()
                Button("删除", role: .destructive) {
                    onDeleteFolder(node.folder)
                }
            }
        }
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
    }
}

private struct SessionTreeRow: View {
    @EnvironmentObject private var appModel: AppViewModel
    let session: SSHSessionProfile
    let onEditSession: (SSHSessionProfile) -> Void
    let onConnectSession: (SSHSessionProfile) -> Void
    let onDuplicateSession: (SSHSessionProfile) -> Void
    let onDeleteSession: (SSHSessionProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.name)
                .font(.body)
                .lineLimit(1)
            Text("\(session.destination):\(session.port)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(rowBackground(isSelected: appModel.selectedSessionID == session.id))
        .onTapGesture {
            appModel.selectedSessionID = session.id
        }
        .onTapGesture(count: 2) {
            appModel.selectedSessionID = session.id
            onConnectSession(session)
        }
        .contextMenu {
            Button("连接") {
                onConnectSession(session)
            }
            Button("编辑") {
                onEditSession(session)
            }
            Button("复制") {
                onDuplicateSession(session)
            }
            Divider()
            Button("删除", role: .destructive) {
                onDeleteSession(session)
            }
        }
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
    }
}
