import SwiftUI

struct ScriptManagerView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @State private var draft = UserScript()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("脚本")
                        .font(.headline)
                    Spacer()
                    Button {
                        draft = UserScript(name: "新建脚本")
                        appModel.selectedScriptID = nil
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                }

                List(selection: $appModel.selectedScriptID) {
                    ForEach(appModel.scripts) { script in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(script.name)
                                .lineLimit(1)
                            Text(script.updatedAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(script.id))
                        .contextMenu {
                            Button("编辑") {
                                select(script)
                            }
                            Button("删除", role: .destructive) {
                                delete(script)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(16)
            .frame(minWidth: 240)

            VStack(alignment: .leading, spacing: 14) {
                Text(appModel.selectedScriptID == nil ? "新增脚本" : "编辑脚本")
                    .font(.title2.weight(.semibold))

                Form {
                    TextField("脚本名称", text: $draft.name)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("脚本内容")
                            .font(.subheadline)
                        TextEditor(text: $draft.content)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 320)
                            .border(Color(nsColor: .separatorColor))
                        Text("脚本会通过系统 ssh 发送到远端 `sh -s` 执行，请避免写入交互式命令。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    if let selected = appModel.selectedScript {
                        Button("删除", role: .destructive) {
                            delete(selected)
                        }
                    }
                    Spacer()
                    Button("重置") {
                        draft = appModel.selectedScript ?? UserScript()
                    }
                    Button("保存") {
                        appModel.saveScript(draft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
                }
            }
            .padding(20)
            .frame(minWidth: 560)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            if let selected = appModel.selectedScript {
                draft = selected
            }
        }
        .onChange(of: appModel.selectedScriptID) { _, _ in
            if let selected = appModel.selectedScript {
                draft = selected
            }
        }
    }

    private func select(_ script: UserScript) {
        appModel.selectedScriptID = script.id
        draft = script
    }

    private func delete(_ script: UserScript) {
        appModel.deleteScript(script)
        draft = appModel.selectedScript ?? UserScript()
    }
}
