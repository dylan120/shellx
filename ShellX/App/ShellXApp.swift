import AppKit
import SwiftUI

enum ShellXPreferences {
    private static let copySelectionOnSelectKey = "preferences.mouseTrackpad.copySelectionOnSelect"

    static var copySelectionOnSelect: Bool {
        get {
            UserDefaults.standard.object(forKey: copySelectionOnSelectKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: copySelectionOnSelectKey)
        }
    }
}

@main
struct ShellXApp: App {
    @StateObject private var appModel = AppViewModel()

    var body: some Scene {
        WindowGroup("会话管理", id: "manager-window") {
            SessionManagerView()
                .environmentObject(appModel)
                .task {
                    // 进入窗口生命周期后再切到普通前台应用，避免在 App.init 阶段 NSApp 尚未创建时触发运行时崩溃。
                    NSApp?.setActivationPolicy(.regular)
                    await appModel.load()
                }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("全局配置…") {
                    openSettingsWindow()
                }
            }
        }

        Settings {
            GlobalPreferencesView()
        }
    }

    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct GlobalPreferencesView: View {
    @State private var copySelectionOnSelect = ShellXPreferences.copySelectionOnSelect

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("全局配置")
                .font(.title2.weight(.semibold))

            GroupBox("鼠标 / 触控板行为") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { copySelectionOnSelect },
                        set: { newValue in
                            copySelectionOnSelect = newValue
                            ShellXPreferences.copySelectionOnSelect = newValue
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text("选中文本复制")
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .help("选中终端文本后自动复制到系统剪贴板。")
                        }
                    }

                    Text("控制终端选区变化后是否自动复制。关闭后仍可继续使用系统复制命令手动复制。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 460, height: 220)
    }
}
