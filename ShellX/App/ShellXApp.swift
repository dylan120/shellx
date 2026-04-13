import AppKit
import SwiftUI

enum ShellXAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

enum ShellXPreferences {
    private static let appearanceModeKey = "preferences.appearance.mode"
    private static let copySelectionOnSelectKey = "preferences.mouseTrackpad.copySelectionOnSelect"
    private static let terminalScrollbackLinesKey = "preferences.terminal.scrollbackLines"

    static let didChangeNotification = Notification.Name("ShellXPreferences.didChange")
    static let minimumTerminalScrollbackLines = 100
    static let maximumTerminalScrollbackLines = 10_000
    static let defaultTerminalScrollbackLines = 500
    static let defaultAppearanceMode: ShellXAppearanceMode = .system

    static var appearanceMode: ShellXAppearanceMode {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: appearanceModeKey),
                  let mode = ShellXAppearanceMode(rawValue: rawValue) else {
                return defaultAppearanceMode
            }
            return mode
        }
        set {
            let existingValue = appearanceMode
            UserDefaults.standard.set(newValue.rawValue, forKey: appearanceModeKey)
            guard existingValue != newValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var copySelectionOnSelect: Bool {
        get {
            UserDefaults.standard.object(forKey: copySelectionOnSelectKey) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: copySelectionOnSelectKey)
        }
    }

    static var terminalScrollbackLines: Int {
        get {
            let storedValue = UserDefaults.standard.object(forKey: terminalScrollbackLinesKey) as? Int
            return normalizedTerminalScrollbackLines(storedValue ?? defaultTerminalScrollbackLines)
        }
        set {
            let normalizedValue = normalizedTerminalScrollbackLines(newValue)
            let existingValue = terminalScrollbackLines
            UserDefaults.standard.set(normalizedValue, forKey: terminalScrollbackLinesKey)
            guard existingValue != normalizedValue else { return }
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    private static func normalizedTerminalScrollbackLines(_ value: Int) -> Int {
        min(max(value, minimumTerminalScrollbackLines), maximumTerminalScrollbackLines)
    }
}

@main
struct ShellXApp: App {
    @StateObject private var appModel = AppViewModel()
    @State private var appearanceMode = ShellXPreferences.appearanceMode

    var body: some Scene {
        WindowGroup("会话管理", id: "manager-window") {
            SessionManagerView()
                .environmentObject(appModel)
                .preferredColorScheme(appearanceMode.preferredColorScheme)
                .onReceive(NotificationCenter.default.publisher(for: ShellXPreferences.didChangeNotification)) { _ in
                    appearanceMode = ShellXPreferences.appearanceMode
                }
                .onChange(of: appearanceMode) { _, newValue in
                    applyAppearance(newValue)
                }
                .task {
                    // 进入窗口生命周期后再切到普通前台应用，避免在 App.init 阶段 NSApp 尚未创建时触发运行时崩溃。
                    applyAppearance(appearanceMode)
                    NSApp?.setActivationPolicy(.regular)
                    await appModel.load()
                }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("新建本机终端") {
                    appModel.openLocalTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()
                SettingsLink {
                    Text("全局配置…")
                }
            }
        }

        Settings {
            GlobalPreferencesView()
                .preferredColorScheme(appearanceMode.preferredColorScheme)
                .onReceive(NotificationCenter.default.publisher(for: ShellXPreferences.didChangeNotification)) { _ in
                    appearanceMode = ShellXPreferences.appearanceMode
                }
        }
    }

    private func applyAppearance(_ mode: ShellXAppearanceMode) {
        NSApp?.appearance = mode.nsAppearance
    }
}

private struct GlobalPreferencesView: View {
    @State private var appearanceMode = ShellXPreferences.appearanceMode
    @State private var copySelectionOnSelect = ShellXPreferences.copySelectionOnSelect
    @State private var terminalScrollbackLines = ShellXPreferences.terminalScrollbackLines

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("全局配置")
                .font(.title2.weight(.semibold))

            GroupBox("界面主题") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("主题模式", selection: Binding(
                        get: { appearanceMode },
                        set: { newValue in
                            appearanceMode = newValue
                            ShellXPreferences.appearanceMode = newValue
                        }
                    )) {
                        ForEach(ShellXAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text("可在跟随系统、浅色和深色之间切换；修改后会立即作用于当前应用窗口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

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

            GroupBox("终端性能") {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(
                        value: Binding(
                            get: { terminalScrollbackLines },
                            set: { newValue in
                                let normalizedValue = min(
                                    max(newValue, ShellXPreferences.minimumTerminalScrollbackLines),
                                    ShellXPreferences.maximumTerminalScrollbackLines
                                )
                                terminalScrollbackLines = normalizedValue
                                ShellXPreferences.terminalScrollbackLines = normalizedValue
                            }
                        ),
                        in: ShellXPreferences.minimumTerminalScrollbackLines...ShellXPreferences.maximumTerminalScrollbackLines,
                        step: 100
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("终端历史行数上限：\(terminalScrollbackLines) 行")
                            Text("滚动回看历史越多，占用内存越高。高频刷屏场景建议保持在 500 到 2000 行。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("该设置会立即作用于已打开的终端标签，用于限制 scrollback 历史，降低长时间日志输出时的内存增长。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 460, height: 430)
    }
}
