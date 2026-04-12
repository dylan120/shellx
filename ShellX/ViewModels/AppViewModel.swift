import Foundation
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var folders: [SessionFolder] = []
    @Published var sessions: [SSHSessionProfile] = []
    @Published var selectedFolderID: UUID?
    @Published var selectedSessionID: UUID?
    @Published var searchText = ""
    @Published var expandedFolderIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private let repository: AppStorageRepository

    init(repository: AppStorageRepository = AppStorageRepository()) {
        self.repository = repository
    }

    func load() async {
        do {
            let workspace = try await repository.loadWorkspace()
            folders = workspace.folders.sorted(by: folderSort)
            sessions = workspace.sessions.sorted(by: sessionSort)
            if selectedSessionID == nil {
                selectedSessionID = filteredSessions.first?.id
            }
            expandedFolderIDs.formUnion(folders.compactMap(\.parentID))
        } catch {
            errorMessage = "读取会话配置失败：\(error.localizedDescription)"
        }
    }

    func persist() {
        let workspace = SessionWorkspace(folders: folders, sessions: sessions)
        Task {
            do {
                try await repository.saveWorkspace(workspace)
            } catch {
                await MainActor.run {
                    self.errorMessage = "保存会话配置失败：\(error.localizedDescription)"
                }
            }
        }
    }

    var selectedSession: SSHSessionProfile? {
        guard let selectedSessionID else { return nil }
        return filteredSessions.first(where: { $0.id == selectedSessionID })
    }

    var filteredSessions: [SSHSessionProfile] {
        sessions
            .filter(matchesSelectedFolder)
            .filter(matchesSearch)
            .sorted(by: sessionSort)
    }

    var rootFolders: [SessionFolderNode] {
        buildNodes(parentID: nil)
    }

    func childFolders(of parentID: UUID?) -> [SessionFolder] {
        folders
            .filter { $0.parentID == parentID }
            .sorted(by: folderSort)
    }

    func folderName(for id: UUID?) -> String {
        guard let id else { return "未分组" }
        return folders.first(where: { $0.id == id })?.name ?? "未分组"
    }

    func indentationLevel(for folderID: UUID?) -> Int {
        var level = 0
        var currentID = folderID
        while let id = currentID, let folder = folders.first(where: { $0.id == id }) {
            level += 1
            currentID = folder.parentID
        }
        return level
    }

    func saveFolder(_ draft: SessionFolder) {
        var folder = draft
        folder.updatedAt = .now
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        } else {
            folders.append(folder)
            expandedFolderIDs.insert(folder.id)
        }
        folders.sort(by: folderSort)
        syncSelectionToVisibleSessions()
        persist()
    }

    func deleteFolder(_ folder: SessionFolder) {
        let parentID = folder.parentID

        // 删除文件夹时，将直属子节点和会话回收至上一级，避免误删整棵树。
        for index in folders.indices where folders[index].parentID == folder.id {
            folders[index].parentID = parentID
            folders[index].updatedAt = .now
        }

        for index in sessions.indices where sessions[index].folderID == folder.id {
            sessions[index].folderID = parentID
            sessions[index].updatedAt = .now
        }

        folders.removeAll { $0.id == folder.id }
        expandedFolderIDs.remove(folder.id)
        if selectedFolderID == folder.id {
            selectedFolderID = parentID
        }
        syncSelectionToVisibleSessions()
        persist()
    }

    func saveSession(_ draft: SSHSessionProfile) {
        var session = draft
        session.updatedAt = .now
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort(by: sessionSort)
        selectedSessionID = session.id
        syncSelectionToVisibleSessions()
        persist()
    }

    func duplicateSession(_ session: SSHSessionProfile) {
        var duplicated = session
        duplicated.id = UUID()
        duplicated.name = "\(session.name)-副本"
        duplicated.createdAt = .now
        duplicated.updatedAt = .now
        duplicated.lastConnectedAt = nil
        saveSession(duplicated)
    }

    func deleteSession(_ session: SSHSessionProfile) {
        sessions.removeAll { $0.id == session.id }
        syncSelectionToVisibleSessions()
        persist()
    }

    func markConnected(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].lastConnectedAt = .now
        sessions[index].updatedAt = .now
        persist()
    }

    func dismissError() {
        errorMessage = nil
    }

    func syncSelectionToVisibleSessions() {
        let visibleIDs = Set(filteredSessions.map(\.id))
        if let selectedSessionID, visibleIDs.contains(selectedSessionID) {
            return
        }
        selectedSessionID = filteredSessions.first?.id
    }

    private func buildNodes(parentID: UUID?) -> [SessionFolderNode] {
        childFolders(of: parentID).map { folder in
            SessionFolderNode(folder: folder, children: buildNodes(parentID: folder.id))
        }
    }

    private func matchesSelectedFolder(_ session: SSHSessionProfile) -> Bool {
        guard let selectedFolderID else { return true }
        if session.folderID == selectedFolderID {
            return true
        }
        guard let folderID = session.folderID else { return false }
        return isDescendant(folderID, of: selectedFolderID)
    }

    private func isDescendant(_ candidateID: UUID, of ancestorID: UUID) -> Bool {
        var currentID: UUID? = candidateID
        while let id = currentID {
            if id == ancestorID {
                return true
            }
            currentID = folders.first(where: { $0.id == id })?.parentID
        }
        return false
    }

    private func matchesSearch(_ session: SSHSessionProfile) -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let key = trimmed.lowercased()
        return session.name.lowercased().contains(key)
            || session.host.lowercased().contains(key)
            || session.username.lowercased().contains(key)
    }

    private func folderSort(lhs: SessionFolder, rhs: SessionFolder) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func sessionSort(lhs: SSHSessionProfile, rhs: SSHSessionProfile) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
