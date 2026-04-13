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
    private var outsideClickMonitor: Any?
    var onSelectionChanged: ((Bool) -> Void)?

    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        let hasSelection = selectedRange().length > 0
        onSelectionChanged?(hasSelection)
        updateOutsideClickMonitor(isNeeded: hasSelection)
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

    deinit {
        removeOutsideClickMonitor()
    }

    private func updateOutsideClickMonitor(isNeeded: Bool) {
        if isNeeded {
            installOutsideClickMonitorIfNeeded()
        } else {
            removeOutsideClickMonitor()
        }
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard self.selectedRange().length > 0 else { return event }

            let clickIsOutsideTerminal: Bool
            if let eventWindow = event.window, eventWindow == self.window {
                let localPoint = self.convert(event.locationInWindow, from: nil)
                clickIsOutsideTerminal = !self.bounds.contains(localPoint)
            } else {
                clickIsOutsideTerminal = true
            }

            if clickIsOutsideTerminal {
                // 点击到终端外部时立即清空选区，避免旧高亮持续保留。
                self.selectNone()
                self.onSelectionChanged?(false)
                self.updateOutsideClickMonitor(isNeeded: false)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
