import AppKit
import SwiftUI

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
