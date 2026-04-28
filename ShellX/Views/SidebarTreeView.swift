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
            Section("会话") {
                AllSessionsRow(
                    onAddFolder: onAddSubfolder,
                    onAddSession: onAddSession
                )

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
        .scrollContentBackground(.hidden)
        .background(sidebarBackgroundColor)
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ShellX")
                    .font(.title3.weight(.semibold))
                Text("\(appModel.filteredSessions.count) 个可见会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(sidebarBackgroundColor)
        }
    }

    private var sidebarBackgroundColor: Color {
        Color(nsColor: .controlBackgroundColor)
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
    let onAddFolder: (SessionFolder?) -> Void
    let onAddSession: (SessionFolder?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("全部会话")
                .font(.callout.weight(appModel.selectedFolderID == nil ? .semibold : .regular))
            Spacer(minLength: 8)
            Text("\(appModel.filteredSessions.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            appModel.selectedFolderID = nil
            appModel.syncSelectionToVisibleSessions()
        }
        .onDrop(of: [SidebarDragItem.itemType.identifier], isTargeted: nil) { providers in
            handleDrop(providers, to: nil)
        }
        .contextMenu {
            Button("新建会话") {
                appModel.selectedFolderID = nil
                onAddSession(nil)
            }
            Button("新建文件夹") {
                appModel.selectedFolderID = nil
                onAddFolder(nil)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(rowBackground(isSelected: appModel.selectedFolderID == nil))
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.14) : .clear
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
                    .frame(width: 18)
                Text(node.folder.name)
                    .font(.callout.weight(appModel.selectedFolderID == node.folder.id ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(appModel.sessions(in: node.folder.id).count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
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
            .listRowBackground(rowBackground(isSelected: appModel.selectedFolderID == node.folder.id))
        }
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.14) : .clear
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
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.callout.weight(appModel.selectedSessionID == session.id ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(session.destination):\(session.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !session.tags.isEmpty {
                Text(session.tags[0])
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 双击需要优先识别，否则 macOS List 中单击选择可能抢先消费点击事件。
        .highPriorityGesture(sessionDoubleClickGesture)
        .simultaneousGesture(sessionSingleClickGesture)
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

    private var iconName: String {
        switch session.authMethod {
        case .sshAgent:
            return "key.horizontal"
        case .privateKey:
            return "doc.text"
        case .password:
            return "lock"
        }
    }

    private var iconColor: Color {
        appModel.selectedSessionID == session.id ? .accentColor : .secondary
    }

    private func rowBackground(isSelected: Bool) -> Color {
        isSelected ? Color.accentColor.opacity(0.16) : .clear
    }

    private var sessionSingleClickGesture: some Gesture {
        TapGesture(count: 1)
            .onEnded {
                appModel.selectedSessionID = session.id
            }
    }

    private var sessionDoubleClickGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                appModel.selectedSessionID = session.id
                onConnectSession(session)
            }
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
