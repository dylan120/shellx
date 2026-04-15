import AppKit
import SwiftTerm
import SwiftUI

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var sessionModel: TerminalSessionViewModel

    final class Coordinator {
        var attachedViewIdentity: ObjectIdentifier?
        var attachedSessionModelIdentity: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ShellXTerminalView {
        let terminalView = ShellXTerminalView(frame: .zero)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.applyRuntimePreferences()
        return terminalView
    }

    func updateNSView(_ nsView: ShellXTerminalView, context: Context) {
        nsView.onSelectionChanged = { hasSelection in
            sessionModel.updateTextSelectionState(hasSelection)
        }

        let currentViewIdentity = ObjectIdentifier(nsView)
        let currentSessionModelIdentity = ObjectIdentifier(sessionModel)
        let isSameView = context.coordinator.attachedViewIdentity == currentViewIdentity
        let isSameSessionModel = context.coordinator.attachedSessionModelIdentity == currentSessionModelIdentity
        guard !(isSameView && isSameSessionModel) else {
            return
        }
        context.coordinator.attachedViewIdentity = currentViewIdentity
        context.coordinator.attachedSessionModelIdentity = currentSessionModelIdentity

        // SwiftUI 初次创建 NSView 时，底层尺寸常常还没稳定。
        // 延后到 update 阶段再附着，避免终端按过大的初始行数启动，导致全屏程序首屏顶部被裁掉。
        // 当 SwiftUI 复用同一个 NSView 但切换到新的会话模型时，也需要重新附着，否则新会话收不到输出。
        DispatchQueue.main.async {
            sessionModel.attachTerminalView(nsView)
        }
    }
}

final class ShellXTerminalView: TerminalView {
    private enum KeyBinding {
        static let moveToLineStart = UInt8(0x01) // Ctrl-A
        static let moveToLineEnd = UInt8(0x05)   // Ctrl-E
    }

    private static var sharedKeyEventMonitor: Any?
    private static var sharedMouseDraggedEventMonitor: Any?
    private static var sharedMouseUpEventMonitor: Any?
    private static var liveViewCount = 0

    private var pendingSelectionCopyTask: DispatchWorkItem?
    private var selectionAutoScrollTimer: Timer?
    private var lastSelectionDragEvent: NSEvent?
    private var outsideClickMonitor: Any?
    private var preferencesObserver: Any?
    var onSelectionChanged: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        startObservingPreferences()
        Self.installSharedKeyEventMonitorIfNeeded()
        Self.installSharedMouseEventMonitorsIfNeeded()
        Self.liveViewCount += 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startObservingPreferences()
        Self.installSharedKeyEventMonitorIfNeeded()
        Self.installSharedMouseEventMonitorsIfNeeded()
        Self.liveViewCount += 1
    }

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
        invalidateSelectionAutoScrollTimer()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
        Self.liveViewCount = max(0, Self.liveViewCount - 1)
        Self.removeSharedKeyEventMonitorIfNeeded()
        Self.removeSharedMouseEventMonitorsIfNeeded()
        removeOutsideClickMonitor()
    }

    func applyRuntimePreferences() {
        // 统一在视图层限制终端历史行数，避免高频输出会话持续推高内存占用。
        changeScrollback(ShellXPreferences.terminalScrollbackLines)
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

    private func handleObservedMouseDragged(_ event: NSEvent) {
        lastSelectionDragEvent = event
        updateSelectionAutoScrollState(with: event)
    }

    private func handleObservedMouseUp() {
        invalidateSelectionAutoScrollTimer()
        lastSelectionDragEvent = nil
    }

    private func updateSelectionAutoScrollState(with event: NSEvent) {
        guard selectedRange().length > 0 else {
            invalidateSelectionAutoScrollTimer()
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        let scrollVelocity = selectionAutoScrollVelocity(for: localPoint)
        guard scrollVelocity != 0 else {
            invalidateSelectionAutoScrollTimer()
            return
        }

        if selectionAutoScrollTimer == nil {
            // SwiftTerm 上游在拖拽越界时只记录了滚动方向，没有持续触发滚动。
            // 这里补一层本地定时器，让用户把鼠标停在终端上下边缘时也能继续扩展选区。
            selectionAutoScrollTimer = Timer.scheduledTimer(
                withTimeInterval: 0.05,
                repeats: true
            ) { [weak self] _ in
                self?.performSelectionAutoScrollStep()
            }
        }
    }

    private func performSelectionAutoScrollStep() {
        guard let event = lastSelectionDragEvent else {
            invalidateSelectionAutoScrollTimer()
            return
        }

        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            invalidateSelectionAutoScrollTimer()
            return
        }

        let localPoint = convert(event.locationInWindow, from: nil)
        let scrollVelocity = selectionAutoScrollVelocity(for: localPoint)
        guard scrollVelocity != 0 else {
            invalidateSelectionAutoScrollTimer()
            return
        }

        if scrollVelocity < 0 {
            scrollUp(lines: -scrollVelocity)
        } else {
            scrollDown(lines: scrollVelocity)
        }

        super.mouseDragged(with: event)
    }

    private func invalidateSelectionAutoScrollTimer() {
        selectionAutoScrollTimer?.invalidate()
        selectionAutoScrollTimer = nil
    }

    private func selectionAutoScrollVelocity(for localPoint: NSPoint) -> Int {
        if localPoint.y > bounds.maxY {
            return -velocity(forOverflow: localPoint.y - bounds.maxY)
        }
        if localPoint.y < bounds.minY {
            return velocity(forOverflow: bounds.minY - localPoint.y)
        }
        return 0
    }

    private func velocity(forOverflow overflow: CGFloat) -> Int {
        switch overflow {
        case 0..<18:
            return 1
        case 18..<64:
            return 3
        default:
            return 10
        }
    }

    private func handleCommandArrowKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 方向键事件常常会附带 numericPad 等系统修饰位，不能再要求“严格等于 Command”，
        // 否则 Command + Left/Right 会被误判为未命中，导致行首/行尾快捷键失效。
        guard modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control) else {
            return false
        }

        let controlByte: UInt8
        switch event.keyCode {
        case 123:
            controlByte = KeyBinding.moveToLineStart
        case 124:
            controlByte = KeyBinding.moveToLineEnd
        default:
            return false
        }

        // 终端里的大多数 readline / prompt-toolkit / CLI 编辑器都能识别 Ctrl-A / Ctrl-E。
        send(data: [controlByte][...])
        return true
    }

    private static func installSharedKeyEventMonitorIfNeeded() {
        guard sharedKeyEventMonitor == nil else { return }
        sharedKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let terminalView = currentFocusedTerminalView(for: event) else {
                return event
            }
            guard terminalView.handleCommandArrowKey(event) else {
                return event
            }
            return nil
        }
    }

    private static func installSharedMouseEventMonitorsIfNeeded() {
        if sharedMouseDraggedEventMonitor == nil {
            sharedMouseDraggedEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { event in
                guard let terminalView = currentFocusedTerminalView(for: event) else {
                    return event
                }
                // 让 SwiftTerm 先处理拖拽选区，再基于最新选区状态补持续自动滚动。
                DispatchQueue.main.async { [weak terminalView] in
                    terminalView?.handleObservedMouseDragged(event)
                }
                return event
            }
        }

        if sharedMouseUpEventMonitor == nil {
            sharedMouseUpEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                currentFocusedTerminalView(for: event)?.handleObservedMouseUp()
                return event
            }
        }
    }

    private static func removeSharedKeyEventMonitorIfNeeded() {
        guard liveViewCount == 0, let sharedKeyEventMonitor else { return }
        NSEvent.removeMonitor(sharedKeyEventMonitor)
        self.sharedKeyEventMonitor = nil
    }

    private static func removeSharedMouseEventMonitorsIfNeeded() {
        guard liveViewCount == 0 else { return }
        if let sharedMouseDraggedEventMonitor {
            NSEvent.removeMonitor(sharedMouseDraggedEventMonitor)
            self.sharedMouseDraggedEventMonitor = nil
        }
        if let sharedMouseUpEventMonitor {
            NSEvent.removeMonitor(sharedMouseUpEventMonitor)
            self.sharedMouseUpEventMonitor = nil
        }
    }

    private static func currentFocusedTerminalView(for event: NSEvent) -> ShellXTerminalView? {
        guard let window = event.window else { return nil }
        guard let firstResponder = window.firstResponder as? NSView else {
            return nil
        }
        return firstResponder.nearestTerminalAncestor()
    }

    private func startObservingPreferences() {
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: ShellXPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyRuntimePreferences()
        }
    }
}

private extension NSView {
    func nearestTerminalAncestor() -> ShellXTerminalView? {
        var currentView: NSView? = self
        while let view = currentView {
            if let terminalView = view as? ShellXTerminalView {
                return terminalView
            }
            currentView = view.superview
        }
        return nil
    }
}
