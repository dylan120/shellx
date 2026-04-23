import SwiftUI

@MainActor
final class ScriptBatchExecutionViewModel: ObservableObject {
    @Published var selectedScriptID: UUID?
    @Published var selectedSessionIDs: Set<UUID> = []
    @Published var results: [ScriptExecutionResult] = []
    @Published var selectedResultID: UUID?
    @Published var isRunning = false
    @Published var argumentText = "" {
        didSet {
            argumentValidationMessage = Self.validationMessage(for: argumentText)
        }
    }
    @Published private(set) var argumentValidationMessage: String?

    private let maxConcurrentExecutions = 6
    private let service = ScriptBatchExecutionService()

    var selectedResult: ScriptExecutionResult? {
        guard let selectedResultID else { return results.first }
        return results.first(where: { $0.id == selectedResultID })
    }

    func toggleSession(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    func selectAll(_ sessions: [SSHSessionProfile]) {
        selectedSessionIDs = Set(sessions.map(\.id))
    }

    func clearSelection() {
        selectedSessionIDs.removeAll()
    }

    func run(scripts: [UserScript], sessions: [SSHSessionProfile]) {
        guard !isRunning,
              let selectedScriptID,
              let script = scripts.first(where: { $0.id == selectedScriptID }) else {
            return
        }

        let targetSessions = sessions.filter { selectedSessionIDs.contains($0.id) }
        guard !targetSessions.isEmpty else { return }
        let scriptArguments: [String]
        do {
            scriptArguments = try ScriptBatchExecutionService.parseArgumentText(argumentText)
            argumentValidationMessage = nil
        } catch {
            argumentValidationMessage = error.localizedDescription
            return
        }

        isRunning = true
        results = targetSessions.map {
            ScriptExecutionResult(sessionID: $0.id, sessionName: $0.name)
        }
        selectedResultID = results.first?.id

        let executionService = service
        let maxConcurrentExecutions = maxConcurrentExecutions
        Task { [weak self] in
            guard let self else { return }
            for chunk in targetSessions.chunked(into: maxConcurrentExecutions) {
                await withTaskGroup(of: SessionScriptRun.self) { group in
                    for session in chunk {
                        self.updateStatus(for: session.id, status: .running)
                        group.addTask {
                            let outcome = await executionService.execute(
                                script: script,
                                session: session,
                                arguments: scriptArguments
                            )
                            return SessionScriptRun(
                                sessionID: session.id,
                                status: outcome.status,
                                output: outcome.output
                            )
                        }
                    }

                    for await run in group {
                        self.updateStatus(for: run.sessionID, status: run.status, output: run.output)
                    }
                }
            }
            self.isRunning = false
        }
    }

    private func updateStatus(
        for sessionID: UUID,
        status: ScriptExecutionStatus,
        output: String? = nil
    ) {
        guard let index = results.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        results[index].status = status
        if let output {
            results[index].output = output
        }
    }

    private static func validationMessage(for argumentText: String) -> String? {
        do {
            _ = try ScriptBatchExecutionService.parseArgumentText(argumentText)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct SessionScriptRun: Sendable {
    let sessionID: UUID
    let status: ScriptExecutionStatus
    let output: String
}

struct ScriptBatchExecutionView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @StateObject private var runner = ScriptBatchExecutionViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("脚本", selection: $runner.selectedScriptID) {
                    Text("请选择脚本").tag(Optional<UUID>.none)
                    ForEach(appModel.scripts) { script in
                        Text(script.name).tag(Optional(script.id))
                    }
                }
                .frame(width: 320)

                Spacer()

                Text("已选择 \(runner.selectedSessionIDs.count) 个会话")
                    .foregroundStyle(.secondary)

                Button("全选") {
                    runner.selectAll(appModel.sessions)
                }
                .disabled(appModel.sessions.isEmpty || runner.isRunning)

                Button("清空") {
                    runner.clearSelection()
                }
                .disabled(runner.selectedSessionIDs.isEmpty || runner.isRunning)

                Button {
                    runner.run(scripts: appModel.scripts, sessions: appModel.sessions)
                } label: {
                    Label("批量执行", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("执行参数，例如：prod \"hello world\" --force", text: $runner.argumentText)
                    .disabled(runner.isRunning)
                Text(runner.argumentValidationMessage ?? "参数会传给远端 `sh -s --`，脚本中可通过 `$1`、`$2`、`$@` 读取。")
                    .font(.footnote)
                    .foregroundStyle(runner.argumentValidationMessage == nil ? .secondary : .red)
            }

            HSplitView {
                SessionScriptSelectionTree(selectedSessionIDs: $runner.selectedSessionIDs)
                    .environmentObject(appModel)
                    .frame(minWidth: 280)

                VStack(spacing: 0) {
                    ScriptExecutionResultList(
                        results: runner.results,
                        selectedResultID: $runner.selectedResultID
                    )
                    Divider()
                    ScriptExecutionOutputView(result: runner.selectedResult)
                }
                .frame(minWidth: 620)
            }
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            runner.selectedScriptID = runner.selectedScriptID ?? appModel.selectedScriptID ?? appModel.scripts.first?.id
        }
    }

    private var canRun: Bool {
        runner.selectedScriptID != nil &&
            !runner.selectedSessionIDs.isEmpty &&
            !runner.isRunning &&
            runner.argumentValidationMessage == nil
    }
}

private struct SessionScriptSelectionTree: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Binding var selectedSessionIDs: Set<UUID>

    var body: some View {
        List {
            Section {
                ForEach(appModel.rootFolders) { node in
                    ScriptFolderSelectionBranch(
                        node: node,
                        selectedSessionIDs: $selectedSessionIDs
                    )
                }

                ForEach(rootSessions) { session in
                    ScriptSessionSelectionRow(
                        session: session,
                        isSelected: selectedSessionIDs.contains(session.id),
                        onToggle: { toggle(session.id) }
                    )
                }
            } header: {
                Text("全部会话树")
            }
        }
        .listStyle(.sidebar)
    }

    private func toggle(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    private var rootSessions: [SSHSessionProfile] {
        appModel.sessions
            .filter { $0.folderID == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct ScriptFolderSelectionBranch: View {
    @EnvironmentObject private var appModel: AppViewModel
    let node: SessionFolderNode
    @Binding var selectedSessionIDs: Set<UUID>

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
            ForEach(folderSessions) { session in
                ScriptSessionSelectionRow(
                    session: session,
                    isSelected: selectedSessionIDs.contains(session.id),
                    onToggle: { toggle(session.id) }
                )
            }

            ForEach(node.children) { child in
                ScriptFolderSelectionBranch(
                    node: child,
                    selectedSessionIDs: $selectedSessionIDs
                )
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.green)
                Text(node.folder.name)
                Spacer()
                Text("\(folderSessions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggle(_ sessionID: UUID) {
        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    private var folderSessions: [SSHSessionProfile] {
        appModel.sessions
            .filter { $0.folderID == node.folder.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct ScriptSessionSelectionRow: View {
    let session: SSHSessionProfile
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isSelected }, set: { _ in onToggle() })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .lineLimit(1)
                Text("\(session.destination):\(session.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 4)
    }
}

private struct ScriptExecutionResultList: View {
    let results: [ScriptExecutionResult]
    @Binding var selectedResultID: UUID?

    var body: some View {
        List(selection: $selectedResultID) {
            ForEach(results) { result in
                HStack(spacing: 10) {
                    Image(systemName: iconName(for: result.status))
                        .foregroundStyle(color(for: result.status))
                    Text(result.sessionName)
                        .lineLimit(1)
                    Spacer()
                    Text(result.status.title)
                        .font(.caption)
                        .foregroundStyle(color(for: result.status))
                }
                .padding(.vertical, 4)
                .tag(Optional(result.id))
            }
        }
        .frame(minHeight: 240)
    }

    private func iconName(for status: ScriptExecutionStatus) -> String {
        switch status {
        case .pending:
            return "clock"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private func color(for status: ScriptExecutionStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .running:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct ScriptExecutionOutputView: View {
    let result: ScriptExecutionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(result?.sessionName ?? "执行输出")
                    .font(.headline)
                Spacer()
                if let result {
                    Text(result.status.title)
                        .foregroundStyle(statusColor(result.status))
                }
            }

            ScrollView {
                Text(outputText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
        }
        .padding(12)
        .frame(minHeight: 260)
    }

    private var outputText: String {
        guard let result else { return "选择一个会话查看输出。" }
        if result.output.isEmpty {
            return result.status.isFinished ? "没有输出。" : "等待输出..."
        }
        return result.output
    }

    private func statusColor(_ status: ScriptExecutionStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .running:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
