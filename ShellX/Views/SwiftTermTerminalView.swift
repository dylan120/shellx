import AppKit
import SwiftTerm
import SwiftUI

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var sessionModel: TerminalSessionViewModel

    func makeNSView(context: Context) -> ShellXTerminalView {
        let terminalView = ShellXTerminalView(frame: .zero)
        terminalView.autoresizingMask = [.width, .height]
        return terminalView
    }

    func updateNSView(_ nsView: ShellXTerminalView, context: Context) {
        nsView.onSelectionChanged = { hasSelection in
            sessionModel.updateTextSelectionState(hasSelection)
        }
        // SwiftUI 初次创建 NSView 时，底层尺寸常常还没稳定。
        // 延后到 update 阶段再附着，避免终端按过大的初始行数启动，导致全屏程序首屏顶部被裁掉。
        DispatchQueue.main.async {
            sessionModel.attachTerminalView(nsView)
        }
    }
}

final class ShellXTerminalView: TerminalView {
    private var pendingSelectionCopyTask: DispatchWorkItem?
    var onSelectionChanged: ((Bool) -> Void)?

    override func resignFirstResponder() -> Bool {
        let response = super.resignFirstResponder()
        if response, selectedRange().length > 0 {
            // 终端失焦后主动清空选区，避免点击到其他区域时旧选区仍持续高亮。
            selectNone()
            onSelectionChanged?(false)
        }
        return response
    }

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        onSelectionChanged?(selectedRange().length > 0)
        guard ShellXPreferences.copySelectionOnSelect else { return }

        pendingSelectionCopyTask?.cancel()
        let copyTask = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let selectedRange = self.selectedRange()
            guard selectedRange.length > 0 else { return }
            self.copy(self)
        }
        pendingSelectionCopyTask = copyTask

        // 选区拖动过程中会连续触发 selectionChanged，这里做一次轻量去抖，
        // 只在用户短暂停止拖动后再自动复制，避免频繁覆盖剪贴板。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: copyTask)
    }
}
