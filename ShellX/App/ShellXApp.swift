import SwiftUI

@main
struct ShellXApp: App {
    @StateObject private var appModel = AppViewModel()

    var body: some Scene {
        WindowGroup("会话管理", id: "manager-window") {
            SessionManagerView()
                .environmentObject(appModel)
                .task {
                    await appModel.load()
                }
        }
        .defaultSize(width: 1280, height: 760)

        WindowGroup("SSH 控制台", id: "terminal-window", for: String.self) { $sessionID in
            TerminalWindowContainerView(sessionID: sessionID)
                .environmentObject(appModel)
        }
        .defaultSize(width: 980, height: 640)

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("ShellX 设置")
                    .font(.title2.weight(.semibold))
                Text("当前版本已接入 SwiftTerm、首次连接 host key 确认和私钥 Keychain 集成，后续版本将继续补充导入能力。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .frame(width: 420, height: 180)
        }
    }
}
