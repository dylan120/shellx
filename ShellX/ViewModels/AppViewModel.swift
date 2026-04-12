import Foundation
import SwiftUI

struct TerminalTabItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case local(shellPath: String)
        case ssh(SSHSessionProfile)
    }

    let id: UUID
    let title: String
    let kind: Kind
}

private struct TerminalTabState: Identifiable, Equatable {
    enum Kind: Equatable {
        case local(shellPath: String)
        case ssh(sessionID: UUID)
    }

    let id: UUID
    let kind: Kind
}

@MainActor
final class AppViewModel: ObservableObject {
    static let localTerminalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultLocalShellPath = "/bin/zsh"

    @Published var folders: [SessionFolder] = []
    @Published var sessions: [SSHSessionProfile] = []
    @Published var selectedFolderID: UUID?
    @Published var selectedSessionID: UUID?
    @Published private var terminalTabs: [TerminalTabState] = []
    @Published var activeTerminalTabID: UUID?
    @Published var searchText = ""
    @Published var expandedFolderIDs: Set<UUID> = []
    @Published var errorMessage: String?

    private let repository: AppStorageRepository
    private let passwordStore: SessionPasswordStore
    private var terminalSessionModels: [UUID: TerminalSessionViewModel] = [:]

    init(
        repository: AppStorageRepository = AppStorageRepository(),
        passwordStore: SessionPasswordStore = SessionPasswordStore()
    ) {
        self.repository = repository
        self.passwordStore = passwordStore
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

        if terminalTabs.isEmpty {
            openLocalTerminal()
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

    var rootSessions: [SSHSessionProfile] {
        sessions(in: nil)
    }

    var openTerminalSessions: [SSHSessionProfile] {
        terminalTabs.compactMap { tab in
            guard case .ssh(let sessionID) = tab.kind else { return nil }
            return sessions.first(where: { $0.id == sessionID })
        }
    }

    var openTerminalTabs: [TerminalTabItem] {
        terminalTabs.compactMap { tab in
            switch tab.kind {
            case .local(let shellPath):
                return TerminalTabItem(
                    id: tab.id,
                    title: "本机终端",
                    kind: .local(shellPath: shellPath)
                )
            case .ssh(let sessionID):
                guard let session = sessions.first(where: { $0.id == sessionID }) else { return nil }
                return TerminalTabItem(
                    id: tab.id,
                    title: session.name,
                    kind: .ssh(session)
                )
            }
        }
    }

    func childFolders(of parentID: UUID?) -> [SessionFolder] {
        folders
            .filter { $0.parentID == parentID }
            .sorted(by: folderSort)
    }

    func sessions(in folderID: UUID?) -> [SSHSessionProfile] {
        sessions
            .filter { $0.folderID == folderID }
            .filter(matchesSearch)
            .sorted(by: sessionSort)
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

    func moveSession(_ sessionID: UUID, to folderID: UUID?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        guard sessions[index].folderID != folderID else { return }

        sessions[index].folderID = folderID
        sessions[index].updatedAt = .now
        sessions.sort(by: sessionSort)
        syncSelectionToVisibleSessions()
        persist()
    }

    func moveFolder(_ folderID: UUID, to parentID: UUID?) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        guard folders[index].parentID != parentID else { return }

        // 禁止把文件夹拖到自己或自己的后代节点下，避免形成循环树结构。
        if folderID == parentID {
            errorMessage = "不能将文件夹移动到自身或其子文件夹中。"
            return
        }

        if let parentID, isDescendant(parentID, of: folderID) {
            errorMessage = "不能将文件夹移动到自身或其子文件夹中。"
            return
        }

        folders[index].parentID = parentID
        folders[index].updatedAt = .now
        folders.sort(by: folderSort)
        syncSelectionToVisibleSessions()
        persist()
    }

    func saveSession(_ submission: SessionEditorSubmission) {
        var session = submission.session
        session.updatedAt = .now

        do {
            switch session.authMethod {
            case .password:
                if session.passwordStoredInKeychain, !submission.password.isEmpty {
                    try passwordStore.savePassword(submission.password, for: session.id)
                } else if !session.passwordStoredInKeychain {
                    try passwordStore.deletePassword(for: session.id)
                }
            case .sshAgent, .privateKey:
                try passwordStore.deletePassword(for: session.id)
            }
        } catch {
            errorMessage = "保存会话密码失败：\(error.localizedDescription)"
            return
        }

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
        duplicated.passwordStoredInKeychain = false
        sessions.append(duplicated)
        sessions.sort(by: sessionSort)
        selectedSessionID = duplicated.id
        syncSelectionToVisibleSessions()
        persist()
    }

    func deleteSession(_ session: SSHSessionProfile) {
        sessions.removeAll { $0.id == session.id }
        closeTerminals(forSessionID: session.id)
        do {
            try passwordStore.deletePassword(for: session.id)
        } catch {
            errorMessage = "删除会话密码失败：\(error.localizedDescription)"
        }
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

    func openTerminal(sessionID: UUID) {
        let tabID = UUID()
        terminalTabs.append(
            TerminalTabState(
                id: tabID,
                kind: .ssh(sessionID: sessionID)
            )
        )
        activeTerminalTabID = tabID
        selectedSessionID = sessionID
    }

    func duplicateTerminal(tabID: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == tabID }) else { return }
        switch tab.kind {
        case .local(let shellPath):
            let duplicatedTabID = UUID()
            terminalTabs.append(
                TerminalTabState(
                    id: duplicatedTabID,
                    kind: .local(shellPath: shellPath)
                )
            )
            activeTerminalTabID = duplicatedTabID
            selectedSessionID = nil
        case .ssh(let sessionID):
            openTerminal(sessionID: sessionID)
        }
    }

    func openLocalTerminal() {
        if !terminalTabs.contains(where: { tab in
            if case .local = tab.kind {
                return true
            }
            return false
        }) {
            terminalTabs.append(
                TerminalTabState(
                    id: Self.localTerminalID,
                    kind: .local(shellPath: Self.defaultLocalShellPath)
                )
            )
        }
        activeTerminalTabID = Self.localTerminalID
        selectedSessionID = nil
    }

    func closeTerminal(tabID: UUID) {
        if let sessionModel = terminalSessionModels.removeValue(forKey: tabID) {
            sessionModel.terminate()
        }
        terminalTabs.removeAll { $0.id == tabID }
        guard activeTerminalTabID == tabID else { return }

        activeTerminalTabID = terminalTabs.last?.id
        syncSelectionToActiveTerminalTab()
    }

    func activateTerminal(tabID: UUID) {
        guard terminalTabs.contains(where: { $0.id == tabID }) else { return }
        activeTerminalTabID = tabID
        syncSelectionToActiveTerminalTab()
    }

    func moveTerminalTab(draggedTabID: UUID, to targetTabID: UUID) {
        guard draggedTabID != targetTabID,
              let sourceIndex = terminalTabs.firstIndex(where: { $0.id == draggedTabID }),
              let destinationIndex = terminalTabs.firstIndex(where: { $0.id == targetTabID }) else {
            return
        }

        let draggedTab = terminalTabs.remove(at: sourceIndex)
        // 右移时，先 remove 会导致目标索引左移一位，这里需要做一次修正。
        let adjustedDestinationIndex = sourceIndex < destinationIndex ? destinationIndex - 1 : destinationIndex
        terminalTabs.insert(draggedTab, at: adjustedDestinationIndex)
    }

    func sourceSessionID(for tabID: UUID) -> UUID? {
        guard let tab = terminalTabs.first(where: { $0.id == tabID }) else { return nil }
        if case .ssh(let sessionID) = tab.kind {
            return sessionID
        }
        return nil
    }

    private func closeTerminals(forSessionID sessionID: UUID) {
        let tabIDs = terminalTabs.compactMap { tab -> UUID? in
            if case .ssh(let tabSessionID) = tab.kind, tabSessionID == sessionID {
                return tab.id
            }
            return nil
        }
        for tabID in tabIDs {
            closeTerminal(tabID: tabID)
        }
    }

    func syncSelectionToVisibleSessions() {
        let visibleIDs = Set(filteredSessions.map(\.id))
        if let selectedSessionID, visibleIDs.contains(selectedSessionID) {
            return
        }
        selectedSessionID = filteredSessions.first?.id
    }

    func terminalSessionModel(for tabID: UUID) -> TerminalSessionViewModel {
        if let existingModel = terminalSessionModels[tabID] {
            return existingModel
        }
        // 标签实例与会话配置解耦后，同一 SSH 会话可以同时打开多个独立终端标签。
        // 因此这里必须按标签实例 ID 缓存终端模型，不能再按会话 ID 复用同一个 PTY。
        let model = TerminalSessionViewModel(passwordStore: passwordStore)
        terminalSessionModels[tabID] = model
        return model
    }

    private func syncSelectionToActiveTerminalTab() {
        guard let activeTerminalTabID,
              let tab = terminalTabs.first(where: { $0.id == activeTerminalTabID }) else {
            selectedSessionID = nil
            return
        }

        switch tab.kind {
        case .local:
            selectedSessionID = nil
        case .ssh(let sessionID):
            selectedSessionID = sessionID
        }
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
