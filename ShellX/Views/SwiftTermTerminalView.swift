import AppKit
import SwiftTerm
import SwiftUI

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var sessionModel: TerminalSessionViewModel
    let isActive: Bool

    final class Coordinator {
        var attachedViewIdentity: ObjectIdentifier?
        var attachedSessionModelIdentity: ObjectIdentifier?
    }

    private let leadingContentInset: CGFloat = 8

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ShellXTerminalContainerView {
        let terminalView = ShellXTerminalView(frame: .zero)
        terminalView.autoresizingMask = [.width, .height]
        terminalView.applyRuntimePreferences()
        return ShellXTerminalContainerView(terminalView: terminalView, leadingContentInset: leadingContentInset)
    }

    func updateNSView(_ nsView: ShellXTerminalContainerView, context: Context) {
        let terminalView = nsView.terminalView
        nsView.leadingContentInset = leadingContentInset
        terminalView.onSelectionChanged = { hasSelection in
            sessionModel.updateTextSelectionState(hasSelection)
        }
        terminalView.isActiveForInput = isActive

        guard isActive else {
            terminalView.clearWindowFocusIfNeeded()
            return
        }

        let currentViewIdentity = ObjectIdentifier(terminalView)
        let currentSessionModelIdentity = ObjectIdentifier(sessionModel)
        let isSameView = context.coordinator.attachedViewIdentity == currentViewIdentity
        let isSameSessionModel = context.coordinator.attachedSessionModelIdentity == currentSessionModelIdentity
        if isSameView && isSameSessionModel {
            terminalView.focusIfNeeded()
            return
        }
        context.coordinator.attachedViewIdentity = currentViewIdentity
        context.coordinator.attachedSessionModelIdentity = currentSessionModelIdentity

        // SwiftUI 初次创建 NSView 时，底层尺寸常常还没稳定。
        // 延后到 update 阶段再附着，避免终端按过大的初始行数启动，导致全屏程序首屏顶部被裁掉。
        // 当 SwiftUI 复用同一个 NSView 但切换到新的会话模型时，也需要重新附着，否则新会话收不到输出。
        DispatchQueue.main.async {
            sessionModel.attachTerminalView(terminalView)
            terminalView.focusIfNeeded()
        }
    }
}

final class ShellXTerminalContainerView: NSView {
    let terminalView: ShellXTerminalView

    var leadingContentInset: CGFloat {
        didSet {
            needsLayout = true
        }
    }

    init(terminalView: ShellXTerminalView, leadingContentInset: CGFloat) {
        self.terminalView = terminalView
        self.leadingContentInset = leadingContentInset
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminalView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        // 这里把缩进放进终端控件内部，避免 SwiftUI 外层 padding 在侧栏和终端页之间形成视觉粗线。
        let leadingInset = max(0, min(leadingContentInset, bounds.width))
        terminalView.frame = NSRect(
            x: bounds.minX + leadingInset,
            y: bounds.minY,
            width: max(0, bounds.width - leadingInset),
            height: bounds.height
        )
        layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
    }
}

final class ShellXTerminalView: TerminalView {
    private enum KeyBinding {
        static let moveToLineStart = UInt8(0x01) // Ctrl-A
        static let moveToLineEnd = UInt8(0x05)   // Ctrl-E
    }

    private struct SelectionDragEventSnapshot {
        let locationInWindow: NSPoint
        let modifierFlags: NSEvent.ModifierFlags
        let windowNumber: Int
        let eventNumber: Int
        let clickCount: Int
        let pressure: Float

        init(event: NSEvent) {
            locationInWindow = event.locationInWindow
            modifierFlags = event.modifierFlags
            windowNumber = event.windowNumber
            eventNumber = event.eventNumber
            clickCount = event.clickCount
            pressure = event.pressure
        }
    }

    private static var sharedKeyEventMonitor: Any?
    private static var sharedMouseDraggedEventMonitor: Any?
    private static var sharedMouseUpEventMonitor: Any?
    private static var liveViewCount = 0

    private var pendingSelectionCopyTask: DispatchWorkItem?
    private var selectionAutoScrollTimer: Timer?
    private var lastSelectionDragEventSnapshot: SelectionDragEventSnapshot?
    private var outsideClickMonitor: Any?
    private var preferencesObserver: Any?
    private var shouldRevealOutputAfterUserInput = false
    weak var attachedSessionModel: TerminalSessionViewModel?
    var onSelectionChanged: ((Bool) -> Void)?
    var isActiveForInput = false

    func focusIfNeeded() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    func clearWindowFocusIfNeeded() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(window.contentView)
    }

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
        // ShellX 优先保证原生文本选择：SwiftTerm 开启鼠标上报时会在输出刷新时清空选区，
        // 并让启用鼠标协议的程序接管拖拽，导致已输出的历史文本无法稳定选中。
        allowMouseReporting = false
        // 统一在视图层限制终端历史行数，避免高频输出会话持续推高内存占用。
        changeScrollback(ShellXPreferences.terminalScrollbackLines)
    }

    func prepareForUserInput() {
        guard isActiveForInput else { return }
        shouldRevealOutputAfterUserInput = true
        revealLatestOutputIfNeeded()
    }

    func feedRemoteOutput(_ data: Data) {
        feed(byteArray: Array(data)[...])
        guard shouldRevealOutputAfterUserInput else { return }
        shouldRevealOutputAfterUserInput = false
        revealLatestOutputIfNeeded()
    }

    private func revealLatestOutputIfNeeded() {
        // 用户在历史区滚动后继续输入命令时，需要回到最新输出；
        // 否则输出实际已经写到底部，但可视区域仍停在历史位置，看起来像光标和输出错位。
        guard selectedRange().length == 0, canScroll else { return }
        scroll(toPosition: 1)
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
        handleObservedMouseDragged(snapshot: SelectionDragEventSnapshot(event: event))
    }

    private func handleObservedMouseDragged(snapshot: SelectionDragEventSnapshot) {
        lastSelectionDragEventSnapshot = snapshot
        updateSelectionAutoScrollState(with: snapshot)
    }

    private func handleObservedMouseUp() {
        invalidateSelectionAutoScrollTimer()
        lastSelectionDragEventSnapshot = nil
    }

    private func updateSelectionAutoScrollState(with snapshot: SelectionDragEventSnapshot) {
        guard selectedRange().length > 0 else {
            invalidateSelectionAutoScrollTimer()
            return
        }

        let localPoint = convert(snapshot.locationInWindow, from: nil)
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
        guard let event = makeSelectionDragEventFromLastSnapshot() else {
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

    private func makeSelectionDragEventFromLastSnapshot() -> NSEvent? {
        guard let snapshot = lastSelectionDragEventSnapshot else { return nil }
        return NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: snapshot.locationInWindow,
            modifierFlags: snapshot.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: snapshot.windowNumber,
            context: nil,
            eventNumber: snapshot.eventNumber,
            clickCount: snapshot.clickCount,
            pressure: snapshot.pressure
        )
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

    private func handleControlShortcutKey(_ event: NSEvent) -> Bool {
        guard let bytes = TerminalKeyInputNormalizer.controlSequence(
            forKeyCode: event.keyCode,
            modifiers: event.modifierFlags
        ) else {
            return false
        }

        send(data: bytes[...])
        return true
    }

    private static func installSharedKeyEventMonitorIfNeeded() {
        guard sharedKeyEventMonitor == nil else { return }
        sharedKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let terminalView = currentFocusedTerminalView(for: event) else {
                return event
            }
            if terminalView.handleControlShortcutKey(event) {
                return nil
            }
            if terminalView.handleCommandArrowKey(event) {
                return nil
            }
            return event
        }
    }

    private static func installSharedMouseEventMonitorsIfNeeded() {
        if sharedMouseDraggedEventMonitor == nil {
            sharedMouseDraggedEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { event in
                guard let terminalView = currentFocusedTerminalView(for: event) else {
                    return event
                }
                // 本地 monitor 在事件分发前执行；延后一轮只保存事件快照，避免定时器复用原始 NSEvent。
                let snapshot = SelectionDragEventSnapshot(event: event)
                DispatchQueue.main.async { [weak terminalView] in
                    terminalView?.handleObservedMouseDragged(snapshot: snapshot)
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
        return focusedTerminalView(from: firstResponder)
    }

    static func focusedTerminalView(from firstResponder: NSView?) -> ShellXTerminalView? {
        guard let firstResponder,
              let terminalView = firstResponder.nearestTerminalAncestor(),
              terminalView.attachedSessionModel != nil,
              terminalView.isActiveForInput else {
            return nil
        }
        return terminalView
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

enum TerminalKeyInputNormalizer {
    private enum ControlByte {
        static let interrupt = UInt8(0x03) // Ctrl-C
    }

    private enum ASCII {
        static let escape = UInt8(0x1B)
        static let leftBracket = UInt8(0x5B)
        static let semicolon = UInt8(0x3B)
        static let colon = UInt8(0x3A)
        static let digitZero = UInt8(0x30)
        static let digitNine = UInt8(0x39)
        static let lowercaseU = UInt8(0x75)
    }

    static func controlSequence(
        forKeyCode keyCode: UInt16,
        modifiers rawModifiers: NSEvent.ModifierFlags
    ) -> [UInt8]? {
        let modifiers = rawModifiers.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.control),
              !modifiers.contains(.command),
              !modifiers.contains(.option) else {
            return nil
        }

        switch keyCode {
        case 8:
            // SwiftTerm 在某些远端协商过扩展键盘协议后，会把 Ctrl-C 编成 CSI u 序列。
            // 交互式 shell 需要收到传统 ETX 字节，否则会把序列当普通文本回显到提示符。
            return [ControlByte.interrupt]
        default:
            return nil
        }
    }

    static func normalizedTerminalInput(_ data: Data) -> Data {
        let bytes = Array(data)
        guard bytes.contains(0x1B) else { return data }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)

        var index = bytes.startIndex
        while index < bytes.endIndex {
            if let normalizedCSIUInput = normalizedCSIUInput(in: bytes, from: index) {
                if let output = normalizedCSIUInput.output {
                    result.append(contentsOf: output)
                }
                index = normalizedCSIUInput.endIndex
                continue
            }

            result.append(bytes[index])
            index += 1
        }

        return Data(result)
    }

    private static func normalizedCSIUInput(
        in bytes: [UInt8],
        from startIndex: Int
    ) -> (output: [UInt8]?, endIndex: Int)? {
        guard startIndex + 4 < bytes.endIndex,
              bytes[startIndex] == ASCII.escape,
              bytes[startIndex + 1] == ASCII.leftBracket else {
            return nil
        }

        var cursor = startIndex + 2
        guard let keyCode = readDecimalInteger(in: bytes, cursor: &cursor) else {
            return nil
        }

        // Kitty/CSI-u 允许在主 codepoint 后附带 alternate key codes，例如 Shift+- 输入 "_"
        // 可能编码成 ESC [ 95:45;2u。执行侧只需要第一个 codepoint，其余 alternate code 跳过。
        while cursor < bytes.endIndex, bytes[cursor] == ASCII.colon {
            cursor += 1
            guard readDecimalInteger(in: bytes, cursor: &cursor) != nil else {
                return nil
            }
        }

        guard cursor < bytes.endIndex, bytes[cursor] == ASCII.semicolon else {
            return nil
        }
        cursor += 1

        guard let modifier = readDecimalInteger(in: bytes, cursor: &cursor) else {
            return nil
        }

        var eventType: Int?
        if cursor < bytes.endIndex, bytes[cursor] == ASCII.colon {
            cursor += 1
            guard let parsedEventType = readDecimalInteger(in: bytes, cursor: &cursor) else {
                return nil
            }
            eventType = parsedEventType
        }

        guard cursor < bytes.endIndex, bytes[cursor] == ASCII.lowercaseU else {
            return nil
        }

        // Kitty/CSI-u 的按键释放事件不应写入 shell；按下和重复事件才还原输入。
        if eventType == 3 {
            return (nil, cursor + 1)
        }

        if modifier == 5, let controlByte = controlByte(forCSIUKeyCode: keyCode) {
            return ([controlByte], cursor + 1)
        }

        if (modifier == 1 || modifier == 2),
           let scalar = UnicodeScalar(keyCode),
           !CharacterSet.controlCharacters.contains(scalar) {
            return (Array(String(scalar).utf8), cursor + 1)
        }

        return nil
    }

    private static func readDecimalInteger(in bytes: [UInt8], cursor: inout Int) -> Int? {
        let start = cursor
        var value = 0

        while cursor < bytes.endIndex {
            let byte = bytes[cursor]
            guard (ASCII.digitZero...ASCII.digitNine).contains(byte) else {
                break
            }
            value = value * 10 + Int(byte - ASCII.digitZero)
            cursor += 1
        }

        return cursor == start ? nil : value
    }

    private static func controlByte(forCSIUKeyCode keyCode: Int) -> UInt8? {
        switch keyCode {
        case 8:
            return 0x08
        case 63:
            return 0x7F
        case 64:
            return 0x00
        case 65...90:
            return UInt8(keyCode - 64)
        case 91...95:
            return UInt8(keyCode - 64)
        case 97...122:
            return UInt8(keyCode - 96)
        default:
            return nil
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
