import AppKit
import SwiftTerm
import SwiftUI

struct SwiftTermTerminalView: NSViewRepresentable {
    @ObservedObject var sessionModel: TerminalSessionViewModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true

        let terminalView = TerminalView(frame: container.bounds)
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)

        sessionModel.attachTerminalView(terminalView)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let terminalView = nsView.subviews.first as? TerminalView {
            terminalView.frame = nsView.bounds
        }
    }
}

