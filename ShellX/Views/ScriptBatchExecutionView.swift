import SwiftUI

@MainActor
final class ScriptBatchExecutionViewModel: ObservableObject {
    private enum Defaults {
        static let timeoutSeconds = ScriptBatchExecutionService.defaultProcessTimeoutSeconds
    }

    @Published var selectedScriptID: UUID?
    @Published var selectedSessionIDs: Set<UUID> = []
    @Published var results: [ScriptExecutionResult] = []
    @Published var selectedResultID: UUID?
    @Published var isRunning = false
    @Published var argumentText = ""
    @Published var timeoutText = "\(Defaults.timeoutSeconds)"

    private let maxConcurrentExecutions = 6
    private let service = ScriptBatchExecutionService()

    var selectedResult: ScriptExecutionResult? {
        guard let selectedResultID else { return results.first }
        return results.first(where: { $0.id == selectedResultID })
    }

    var argumentValidationMessage: String? {
        Self.validationMessage(for: argumentText)
    }

    var timeoutValidationMessage: String? {
        Self.timeoutValidationMessage(for: timeoutText)
    }

    var hasRunningResults: Bool {
        results.contains(where: { $0.status == .running })
    }

    var selectedRunningSessionID: UUID? {
        guard let selectedResult, selectedResult.status == .running else { return nil }
        return selectedResult.sessionID
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
              let script = scripts.first(where: { $0.id == selectedScriptID }),
              let timeoutSeconds = Self.timeoutSeconds(from: timeoutText) else {
            return
        }

        let targetSessions = sessions.filter { selectedSessionIDs.contains($0.id) }
        guard !targetSessions.isEmpty else { return }
        guard let scriptArguments = try? ScriptBatchExecutionService.parseArgumentText(argumentText) else { return }

        isRunning = true
        results = targetSessions.map {
            ScriptExecutionResult(sessionID: $0.id, sessionName: $0.name)
        }
        selectedResultID = results.first?.id

        let executionService = service
        let maxConcurrentExecutions = maxConcurrentExecutions
        let selectedSessions = targetSessions
        Task { [weak self] in
            guard let self else { return }
            for chunk in selectedSessions.chunked(into: maxConcurrentExecutions) {
                await withTaskGroup(of: SessionScriptRun.self) { group in
                    for session in chunk {
                        self.updateStatus(for: session.id, status: .running)
                        let session = session
                        let script = script
                        let scriptArguments = scriptArguments
                        let executionService = executionService
                        group.addTask {
                            let outcome = await executionService.execute(
                                script: script,
                                session: session,
                                arguments: scriptArguments,
                                timeoutSeconds: timeoutSeconds
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

    func terminateSelectedRun() {
        guard let sessionID = selectedRunningSessionID else { return }
        service.terminate(sessionID: sessionID)
    }

    func terminateRunningSessions() {
        let runningSessionIDs = results
            .filter { $0.status == .running }
            .map(\.sessionID)
        guard !runningSessionIDs.isEmpty else { return }
        service.terminate(sessionIDs: runningSessionIDs)
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

    private static func timeoutSeconds(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    private static func timeoutValidationMessage(for text: String) -> String? {
        guard timeoutSeconds(from: text) == nil else { return nil }
        return "超时时间必须是大于 0 的整数秒。"
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
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("批量执行脚本")
                        .font(.title2.weight(.semibold))
                    Text(executionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("全选") {
                    runner.selectAll(appModel.sessions)
                }
                .disabled(appModel.sessions.isEmpty || runner.isRunning)

                Button("清空") {
                    runner.clearSelection()
                }
                .disabled(runner.selectedSessionIDs.isEmpty || runner.isRunning)

                Button("终止选中") {
                    runner.terminateSelectedRun()
                }
                .disabled(runner.selectedRunningSessionID == nil)

                Button("终止运行中") {
                    runner.terminateRunningSessions()
                }
                .disabled(!runner.hasRunningResults)

                Button {
                    runner.run(scripts: appModel.scripts, sessions: appModel.sessions)
                } label: {
                    Label("批量执行", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }

            ShellXSection("执行配置") {
                HStack(spacing: 12) {
                    Picker("脚本", selection: $runner.selectedScriptID) {
                        Text("请选择脚本").tag(Optional<UUID>.none)
                        ForEach(appModel.scripts) { script in
                            Text(script.name).tag(Optional(script.id))
                        }
                    }
                    .frame(width: 320)

                    ShellXStatusPill(
                        title: "已选择 \(runner.selectedSessionIDs.count) 个会话",
                        systemImage: "checklist",
                        color: runner.selectedSessionIDs.isEmpty ? .secondary : .accentColor
                    )

                    Spacer()

                    HStack(spacing: 6) {
                        Text("超时")
                            .foregroundStyle(.secondary)
                        TextField("3600", text: $runner.timeoutText)
                            .frame(width: 96)
                            .disabled(runner.isRunning)
                        Text("秒")
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    TextField("执行参数，例如：prod \"hello world\" --force", text: $runner.argumentText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(runner.isRunning)
                    if let argumentValidationMessage = runner.argumentValidationMessage {
                        Text(argumentValidationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text("参数会传给远端 `sh -s --`，脚本中可通过 `$1`、`$2`、`$@` 读取。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let timeoutValidationMessage = runner.timeoutValidationMessage {
                    Text(timeoutValidationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("单台主机脚本执行超过设定时间会自动终止，默认 3600 秒。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(runner.isRunning)

            if !runner.results.isEmpty {
                HStack(spacing: 8) {
                    ForEach(statusSummary, id: \.title) { item in
                        ShellXStatusPill(title: item.title, systemImage: item.icon, color: item.color)
                    }
                    Spacer()
                }
            }

            HSplitView {
                ShellXSection("目标会话") {
                    SessionScriptSelectionTree(selectedSessionIDs: $runner.selectedSessionIDs)
                        .environmentObject(appModel)
                        .frame(minWidth: 280)
                }
                .frame(minWidth: 300)
                .disabled(runner.isRunning)

                VStack(spacing: 0) {
                    ScriptExecutionResultList(
                        results: runner.results,
                        selectedResultID: $runner.selectedResultID,
                        onTerminate: { sessionID in
                            runner.selectedResultID = runner.results.first(where: { $0.sessionID == sessionID })?.id
                            runner.terminateSelectedRun()
                        }
                    )
                    Divider()
                    ScriptExecutionOutputView(result: runner.selectedResult)
                }
                .frame(minWidth: 620)
                .background(ShellXUI.sectionBackground, in: RoundedRectangle(cornerRadius: ShellXUI.sectionCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ShellXUI.sectionCornerRadius)
                        .strokeBorder(ShellXUI.separator.opacity(0.65), lineWidth: 1)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 980, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            runner.selectedScriptID = runner.selectedScriptID ?? appModel.selectedScriptID ?? appModel.scripts.first?.id
        }
    }

    private var canRun: Bool {
        runner.selectedScriptID != nil &&
            !runner.selectedSessionIDs.isEmpty &&
            !runner.isRunning &&
            runner.argumentValidationMessage == nil &&
            runner.timeoutValidationMessage == nil
    }

    private var executionSummary: String {
        if runner.results.isEmpty {
            return "选择脚本和目标会话后执行，最多同时运行 6 台主机。"
        }
        return statusSummary.map(\.title).joined(separator: " · ")
    }

    private var statusSummary: [ScriptStatusSummaryItem] {
        let pending = runner.results.filter { $0.status == .pending }.count
        let running = runner.results.filter { $0.status == .running }.count
        let succeeded = runner.results.filter { $0.status == .succeeded }.count
        let failed = runner.results.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        return [
            ScriptStatusSummaryItem(title: "等待 \(pending)", icon: "clock", color: .secondary),
            ScriptStatusSummaryItem(title: "运行 \(running)", icon: "arrow.triangle.2.circlepath", color: .orange),
            ScriptStatusSummaryItem(title: "成功 \(succeeded)", icon: "checkmark.circle.fill", color: .green),
            ScriptStatusSummaryItem(title: "失败 \(failed)", icon: "xmark.octagon.fill", color: .red)
        ]
    }
}

private struct ScriptStatusSummaryItem {
    let title: String
    let icon: String
    let color: Color
}

private struct SessionScriptSelectionTree: View {
    @EnvironmentObject private var appModel: AppViewModel
    @Binding var selectedSessionIDs: Set<UUID>

    var body: some View {
        List {
            Section("全部会话树") {
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
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
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
    let onTerminate: (UUID) -> Void

    var body: some View {
        List(selection: $selectedResultID) {
            ForEach(results) { result in
                HStack(spacing: 10) {
                    Image(systemName: iconName(for: result.status))
                        .foregroundStyle(ShellXUI.scriptStatusColor(result.status))
                    Text(result.sessionName)
                        .lineLimit(1)
                    Spacer()
                    Text(result.status.title)
                        .font(.caption)
                        .foregroundStyle(ShellXUI.scriptStatusColor(result.status))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(ShellXUI.scriptStatusColor(result.status).opacity(0.10), in: Capsule())
                }
                .padding(.vertical, 4)
                .tag(Optional(result.id))
                .contextMenu {
                    if result.status == .running {
                        Button("终止该主机执行") {
                            onTerminate(result.sessionID)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 240)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
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
            .background(ShellXUI.subtleBackground, in: RoundedRectangle(cornerRadius: ShellXUI.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ShellXUI.controlCornerRadius)
                    .strokeBorder(ShellXUI.separator.opacity(0.8), lineWidth: 1)
            }
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
        ShellXUI.scriptStatusColor(status)
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
