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

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("ShellX 设置")
                    .font(.title2.weight(.semibold))
                Text("当前版本已接入 SwiftTerm、首次连接 host key 确认、账号密码 Keychain 存储和私钥 Keychain 集成。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .frame(width: 420, height: 180)
        }
    }
}
