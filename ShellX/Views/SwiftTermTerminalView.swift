import AppKit
import SwiftTerm
import SwiftUI

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var sessionModel: TerminalSessionViewModel

    func makeNSView(context: Context) -> TerminalView {
        let terminalView = TerminalView(frame: .zero)
        terminalView.autoresizingMask = [.width, .height]
        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // SwiftUI 初次创建 NSView 时，底层尺寸常常还没稳定。
        // 延后到 update 阶段再附着，避免终端按过大的初始行数启动，导致全屏程序首屏顶部被裁掉。
        DispatchQueue.main.async {
            sessionModel.attachTerminalView(nsView)
        }
    }
}
