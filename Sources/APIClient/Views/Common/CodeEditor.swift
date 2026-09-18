import AppKit
import SwiftUI
import ApiClientCore

/// 带语法着色的代码编辑器。
///
/// 为什么不用 SwiftUI 的 `TextEditor`：它拿不到属性字符串，也就没法做 JSON 高亮，
/// 更没法把「当前滚动到哪、光标在哪」读出来。这里的编辑器基于 NSTextView，
/// 额外提供两件事：
/// - **位置记忆**：每个 `anchorKey`（请求体就是「哪种请求体方式」）各自记一份光标与滚动位置；
/// - **自动定位**：`locateToken` 变化时把视图定位到正文起点，也就是当前请求方式的内容所在处。
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: CodeLanguage = .plain
    var isEditable: Bool = true
    /// 位置记忆的键。同一个键 = 同一份位置。
    var anchorKey: String?
    var anchorStore: Binding<[String: BodyEditorAnchor]>?
    /// 变化时触发一次自动定位（首次出现也算一次）。
    var locateToken: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // 写代码时这些「智能」替换全是负担：引号会被换成中文引号、双空格变句号。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        // 记录每次编辑改动的范围：着色只重做被改到的那几行，不再整篇重排。
        textView.textStorage?.delegate = context.coordinator
        textView.drawsBackground = false
        textView.font = DS.fontNS.mono
        textView.textColor = DS.nsColor.textPrimary
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: DS.space.md, height: DS.space.md)

        // 不自动换行：JSON 折行后层级关系就看不出来了，宁可横向滚动。
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.observeScroll(of: scrollView)
        textView.onAppearanceChange = { [weak coordinator = context.coordinator] in
            coordinator?.highlight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CodeTextView else { return }

        textView.isEditable = isEditable
        if context.coordinator.language != language {
            context.coordinator.language = language
            context.coordinator.highlight()
        }
        // 和上次同步过的字符串比：内容没变时两者共用同一份存储，比较是 O(1)；
        // 直接读 `textView.string` 每次都要把整篇文本从 NSTextStorage 拷出来。
        if text != context.coordinator.lastSyncedText {
            context.coordinator.apply(text, to: textView)
        }
        if context.coordinator.lastLocateToken != locateToken {
            context.coordinator.lastLocateToken = locateToken
            context.coordinator.locate()
        }
    }

    // MARK: - 协调器

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CodeEditor
        var language: CodeLanguage
        /// 初值 -1：首次布局时也会走一次自动定位。
        var lastLocateToken = -1
        /// 最近一次与 SwiftUI 侧同步过的文本（双向都算）。
        var lastSyncedText = ""
        weak var textView: CodeTextView?

        private var isApplyingProgrammaticEdit = false
        private var scrollObserver: NSObjectProtocol?
        /// 本次用户编辑改动到的字符范围（由 NSTextStorageDelegate 记录，textDidChange 消费）。
        private var pendingEditedRange: NSRange?

        init(_ parent: CodeEditor) {
            self.parent = parent
            self.language = parent.language
        }

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        // MARK: 编辑回调

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticEdit,
                  let textView = notification.object as? NSTextView else { return }
            let text = textView.string
            lastSyncedText = text
            parent.text = text
            highlight(editedRange: pendingEditedRange)
            pendingEditedRange = nil
            saveAnchor()
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            pendingEditedRange = pendingEditedRange.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            saveAnchor()
        }

        // MARK: 着色

        /// 只重新着色被改到的那几行。JSON 的 token 不跨行（字符串遇到换行即终止），
        /// 所以按段落重算是安全的；整篇 `setAttributes` 会让 NSTextView 把全文重新排版，
        /// 大请求体每敲一个字就卡一下的根源就在这里。
        func highlight(editedRange: NSRange?) {
            guard let editedRange, let textView, let storage = textView.textStorage else {
                highlight()
                return
            }
            // 超过全文着色上限的文档整篇都不上色，局部也别上，否则颜色会一段有一段没有。
            guard storage.length <= CodeTokenizer.highlightLimit else { return }

            let content = storage.mutableString
            let clamped = NSIntersectionRange(editedRange, NSRange(location: 0, length: content.length))
            let lines = content.paragraphRange(for: clamped)
            guard lines.length > 0 else { return }

            let base = baseAttributes
            storage.beginEditing()
            storage.setAttributes(base, range: lines)
            let snippet = content.substring(with: lines)
            for token in CodeTokenizer.tokens(in: snippet, language: language) {
                let range = NSRange(location: lines.location + token.range.location, length: token.range.length)
                guard NSMaxRange(range) <= NSMaxRange(lines) else { continue }
                storage.addAttributes([.foregroundColor: CodeTokenizer.color(for: token.kind)], range: range)
            }
            storage.endEditing()
            textView.typingAttributes = base
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let selection = textView.selectedRanges
            let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin
            let base = baseAttributes

            storage.beginEditing()
            storage.setAttributes(base, range: full)
            for token in CodeTokenizer.tokens(in: textView.string, language: language) {
                // 内容被外部替换后，旧的 token 范围可能已经越界，先夹一下再上色。
                guard NSMaxRange(token.range) <= storage.length else { continue }
                storage.addAttributes([.foregroundColor: CodeTokenizer.color(for: token.kind)], range: token.range)
            }
            storage.endEditing()

            textView.typingAttributes = base
            textView.selectedRanges = selection
            if let scrollOrigin, let clip = textView.enclosingScrollView?.contentView {
                clip.scroll(to: scrollOrigin)
            }
        }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: DS.fontNS.mono, .foregroundColor: DS.nsColor.textPrimary]
        }

        // MARK: 文本同步

        func apply(_ newText: String, to textView: NSTextView) {
            isApplyingProgrammaticEdit = true
            lastSyncedText = newText
            let caret = textView.selectedRange().location
            textView.string = newText
            pendingEditedRange = nil
            textView.setSelectedRange(NSRange(location: TextLocator.clamp(caret, in: newText), length: 0))
            isApplyingProgrammaticEdit = false
            highlight()
        }

        // MARK: 自动定位

        func locate() {
            guard let textView else { return }
            let stored = parent.anchorKey.flatMap { parent.anchorStore?.wrappedValue[$0] }

            if let stored, stored.caret > 0 || stored.scrollY > 0 {
                restore(stored, in: textView)
                return
            }

            // 没有历史位置：定位到正文起点（跳过 JSON 前面那几行空行）。
            let start = TextLocator.contentStart(in: textView.string)
            textView.setSelectedRange(NSRange(location: start, length: 0))
            textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        }

        private func restore(_ anchor: BodyEditorAnchor, in textView: NSTextView) {
            let location = TextLocator.clamp(anchor.caret, in: textView.string)
            let length = min(anchor.selectionLength, textView.string.utf16.count - location)
            textView.setSelectedRange(NSRange(location: location, length: max(0, length)))

            guard let clip = textView.enclosingScrollView?.contentView else { return }
            let maxY = max(0, textView.frame.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(max(0, CGFloat(anchor.scrollY)), maxY)))
            textView.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        // MARK: 位置记忆

        func observeScroll(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.saveAnchor()
            }
        }

        private func saveAnchor() {
            guard let textView, let key = parent.anchorKey, let store = parent.anchorStore else { return }
            let selection = textView.selectedRange()
            let scrollY = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
            let anchor = BodyEditorAnchor(
                caret: selection.location,
                selectionLength: selection.length,
                scrollY: Double(scrollY)
            )
            guard store.wrappedValue[key] != anchor else { return }
            store.wrappedValue[key] = anchor
        }
    }
}

/// 外观切换（浅色 / 深色）后要重新解析动态颜色，否则高亮会停留在旧主题上。
final class CodeTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
