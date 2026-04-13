import UniformTypeIdentifiers
import SwiftUI

struct SidebarTreeView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let onAddSubfolder: (SessionFolder?) -> Void
    let onAddSession: (SessionFolder?) -> Void
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
                        onAddSession: onAddSession,
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

private enum SidebarDragItem {
    static let itemType = UTType.plainText

    case folder(UUID)
    case session(UUID)

    var payload: String {
        switch self {
        case .folder(let id):
            return "folder:\(id.uuidString)"
        case .session(let id):
            return "session:\(id.uuidString)"
        }
    }

    init?(payload: String) {
        let components = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2, let id = UUID(uuidString: components[1]) else { return nil }
        switch components[0] {
        case "folder":
            self = .folder(id)
        case "session":
            self = .session(id)
        default:
            return nil
        }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.selectedFolderID = nil
            appModel.syncSelectionToVisibleSessions()
        }
        .onDrop(of: [SidebarDragItem.itemType.identifier], isTargeted: nil) { providers in
            handleDrop(providers, to: nil)
        }
        .listRowInsets(EdgeInsets())
    }

    private func handleDrop(_ providers: [NSItemProvider], to folderID: UUID?) -> Bool {
        SidebarDragItem.load(from: providers.first) { item in
            switch item {
            case .folder(let draggedFolderID):
                appModel.moveFolder(draggedFolderID, to: folderID)
            case .session(let draggedSessionID):
                appModel.moveSession(draggedSessionID, to: folderID)
            }
        }
        return !providers.isEmpty
    }
}

private struct FolderBranchView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let node: SessionFolderNode
    let onAddSubfolder: (SessionFolder?) -> Void
    let onAddSession: (SessionFolder?) -> Void
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
                    onAddSession: onAddSession,
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
                Image(systemName: "folder.fill")
                    .foregroundStyle(.green)
                Text(node.folder.name)
                Spacer(minLength: 8)
                Text("\(appModel.sessions(in: node.folder.id).count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                appModel.selectedFolderID = node.folder.id
                appModel.syncSelectionToVisibleSessions()
            }
            .onDrag {
                NSItemProvider(object: SidebarDragItem.folder(node.folder.id).payload as NSString)
            }
            .onDrop(of: [SidebarDragItem.itemType.identifier], isTargeted: nil) { providers in
                handleDrop(providers, to: node.folder.id)
            }
            .contextMenu {
                Button("新建会话") {
                    onAddSession(node.folder)
                }
                Button("新建子文件夹") {
                    onAddSubfolder(node.folder)
                }
                Divider()
                Button("重命名") {
                    onRenameFolder(node.folder)
                }
                Divider()
                Button("删除", role: .destructive) {
                    onDeleteFolder(node.folder)
                }
            }
            .listRowInsets(EdgeInsets())
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], to folderID: UUID?) -> Bool {
        SidebarDragItem.load(from: providers.first) { item in
            switch item {
            case .folder(let draggedFolderID):
                appModel.moveFolder(draggedFolderID, to: folderID)
            case .session(let draggedSessionID):
                appModel.moveSession(draggedSessionID, to: folderID)
            }
        }
        return !providers.isEmpty
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.selectedSessionID = session.id
        }
        .onTapGesture(count: 2) {
            appModel.selectedSessionID = session.id
            onConnectSession(session)
        }
        .onDrag {
            NSItemProvider(object: SidebarDragItem.session(session.id).payload as NSString)
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
        .listRowInsets(EdgeInsets())
        .listRowBackground(rowBackground(isSelected: appModel.selectedSessionID == session.id))
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.16) : .clear
    }
}

private extension SidebarDragItem {
    static func load(from provider: NSItemProvider?, perform: @escaping (SidebarDragItem) -> Void) {
        guard let provider,
              provider.hasItemConformingToTypeIdentifier(itemType.identifier) else {
            return
        }

        provider.loadItem(forTypeIdentifier: itemType.identifier, options: nil) { item, _ in
            let payload: String?
            if let data = item as? Data {
                payload = String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                payload = string
            } else if let string = item as? NSString {
                payload = string as String
            } else {
                payload = nil
            }

            guard let payload, let dragItem = SidebarDragItem(payload: payload) else { return }
            DispatchQueue.main.async {
                perform(dragItem)
            }
        }
    }
}
