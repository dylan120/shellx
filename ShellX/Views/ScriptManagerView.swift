import AppKit
import SwiftUI

struct ScriptManagerView: View {
    @EnvironmentObject private var appModel: AppViewModel
    @State private var draft = UserScript()

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("脚本")
                        .font(.headline)
                    Spacer()
                    Button {
                        draft = UserScript(name: "新建脚本")
                        appModel.selectedScriptID = nil
                    } label: {
                        Label("新增", systemImage: "plus")
                    }
                }

                List(selection: $appModel.selectedScriptID) {
                    ForEach(appModel.scripts) { script in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(script.name)
                                .lineLimit(1)
                            Text(script.updatedAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(script.id))
                        .contextMenu {
                            Button("编辑") {
                                select(script)
                            }
                            Button("删除", role: .destructive) {
                                delete(script)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .padding(16)
            .frame(minWidth: 240)

            VStack(alignment: .leading, spacing: 14) {
                Text(appModel.selectedScriptID == nil ? "新增脚本" : "编辑脚本")
                    .font(.title2.weight(.semibold))

                Form {
                    TextField("脚本名称", text: $draft.name)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("脚本内容")
                                .font(.subheadline)
                            Spacer()
                            Picker("语法", selection: $draft.language) {
                                ForEach(ScriptLanguage.allCases) { language in
                                    Text(language.title).tag(language)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }
                        SyntaxHighlightedScriptEditor(text: $draft.content, language: draft.language)
                            .frame(minHeight: 320)
                            .border(Color(nsColor: .separatorColor))
                        Text("脚本会通过系统 ssh 发送到远端 `sh -s` 执行，请避免写入交互式命令。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    if let selected = appModel.selectedScript {
                        Button("删除", role: .destructive) {
                            delete(selected)
                        }
                    }
                    Spacer()
                    Button("重置") {
                        draft = appModel.selectedScript ?? UserScript()
                    }
                    Button("保存") {
                        appModel.saveScript(draft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
                }
            }
            .padding(20)
            .frame(minWidth: 560)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            if let selected = appModel.selectedScript {
                draft = selected
            }
        }
        .onChange(of: appModel.selectedScriptID) { _, _ in
            if let selected = appModel.selectedScript {
                draft = selected
            }
        }
    }

    private func select(_ script: UserScript) {
        appModel.selectedScriptID = script.id
        draft = script
    }

    private func delete(_ script: UserScript) {
        appModel.deleteScript(script)
        draft = appModel.selectedScript ?? UserScript()
    }
}

private struct SyntaxHighlightedScriptEditor: NSViewRepresentable {
    @Binding var text: String
    let language: ScriptLanguage

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.applySyntaxHighlighting(to: textView, language: language)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.language = language
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.applySyntaxHighlighting(to: textView, language: language)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var language: ScriptLanguage
        private var isApplyingHighlight = false

        init(text: Binding<String>, language: ScriptLanguage) {
            self.text = text
            self.language = language
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            applySyntaxHighlighting(to: textView)
        }

        func applySyntaxHighlighting(to textView: NSTextView, language: ScriptLanguage? = nil) {
            guard !isApplyingHighlight, let storage = textView.textStorage else { return }
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }

            let selectedRanges = textView.selectedRanges
            let currentLanguage = language ?? self.language
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let baseFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

            // 这里做轻量词法着色，不改变脚本文本本身，也不参与远端执行语义。
            storage.beginEditing()
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ], range: fullRange)

            applyPatterns(Self.numberPatterns, color: .systemPurple, in: storage, text: textView.string)
            applyPatterns(Self.patterns(for: currentLanguage).keywords, color: .systemBlue, in: storage, text: textView.string)
            applyPatterns(Self.patterns(for: currentLanguage).commands, color: .systemTeal, in: storage, text: textView.string)
            applyPatterns(Self.commentPatterns(for: currentLanguage), color: .systemGreen, in: storage, text: textView.string)
            applyPatterns(Self.stringPatterns, color: .systemRed, in: storage, text: textView.string)
            storage.endEditing()

            textView.selectedRanges = selectedRanges
        }

        private func applyPatterns(
            _ patterns: [String],
            color: NSColor,
            in storage: NSTextStorage,
            text: String
        ) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            for pattern in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                    continue
                }
                expression.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                    guard let match else { return }
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }

        private static let numberPatterns = [
            #"(?<![\w.])-?\b\d+(?:\.\d+)?\b"#
        ]

        private static let stringPatterns = [
            #""(?:\\.|[^"\\])*""#,
            #"'(?:\\.|[^'\\])*'"#
        ]

        private static func commentPatterns(for language: ScriptLanguage) -> [String] {
            switch language {
            case .shell:
                return [#"(?m)^\s*#.*$"#, #"(?m)(?<=\s)#.*$"#]
            case .python:
                return [#"(?m)^\s*#.*$"#, #"(?m)(?<=\s)#.*$"#]
            }
        }

        private static func patterns(for language: ScriptLanguage) -> (keywords: [String], commands: [String]) {
            switch language {
            case .shell:
                return (
                    keywords: [
                        #"\b(?:if|then|else|elif|fi|for|while|until|do|done|case|esac|function|in|select|time)\b"#,
                        #"\b(?:export|readonly|local|return|break|continue|exit|set|unset|trap|shift)\b"#
                    ],
                    commands: [
                        #"\b(?:echo|printf|test|cd|pwd|read|source|eval|exec|ssh|scp|rsync|grep|sed|awk|find|xargs|curl|wget|tar|mkdir|rm|mv|cp|chmod|chown|sudo)\b"#,
                        #"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#
                    ]
                )
            case .python:
                return (
                    keywords: [
                        #"\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#
                    ],
                    commands: [
                        #"\b(?:print|len|range|enumerate|zip|dict|list|set|tuple|str|int|float|bool|open|super|self|classmethod|staticmethod)\b"#,
                        #"\b[A-Za-z_][A-Za-z0-9_]*(?=\()"#
                    ]
                )
            }
        }
    }
}
