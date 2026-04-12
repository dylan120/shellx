import SwiftUI

struct SidebarTreeView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let onAddSubfolder: (SessionFolder?) -> Void
    let onRenameFolder: (SessionFolder) -> Void
    let onDeleteFolder: (SessionFolder) -> Void

    var body: some View {
        List(selection: $appModel.selectedFolderID) {
            Label("全部会话", systemImage: "tray.full")
                .contentShape(Rectangle())
                .onTapGesture {
                    appModel.selectedFolderID = nil
                }
                .tag(Optional<UUID>.none)

            ForEach(appModel.rootFolders) { node in
                FolderBranchView(
                    node: node,
                    onAddSubfolder: onAddSubfolder,
                    onRenameFolder: onRenameFolder,
                    onDeleteFolder: onDeleteFolder
                )
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FolderBranchView: View {
    @EnvironmentObject private var appModel: AppViewModel
    let node: SessionFolderNode
    let onAddSubfolder: (SessionFolder?) -> Void
    let onRenameFolder: (SessionFolder) -> Void
    let onDeleteFolder: (SessionFolder) -> Void

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
            ForEach(node.children) { child in
                FolderBranchView(
                    node: child,
                    onAddSubfolder: onAddSubfolder,
                    onRenameFolder: onRenameFolder,
                    onDeleteFolder: onDeleteFolder
                )
            }
        } label: {
            HStack {
                Label(node.folder.name, systemImage: "folder")
                Spacer(minLength: 8)
                Text("\(appModel.sessions.filter { $0.folderID == node.folder.id }.count)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                appModel.selectedFolderID = node.folder.id
            }
        }
        .tag(Optional(node.folder.id))
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
