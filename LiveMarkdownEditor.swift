import SwiftUI
import AppKit

enum MarkdownFormatStyle: String {
    case heading1, heading2, heading3, body
    case bold, italic, underline, highlight, strikethrough
    case bulletList, numberedList, taskList, link, divider
}

struct MarkdownFormatCommand: Equatable {
    let id = UUID()
    let style: MarkdownFormatStyle
}

enum MarkdownStorageCodec {
    static func source(from storage: NSAttributedString) -> String {
        let ns = storage.string as NSString
        var output = ""
        var display = 0
        while display < storage.length {
            var effective = NSRange(location: display, length: 0)
            if let attachment = storage.attribute(.attachment, at: display,
                                                  effectiveRange: &effective) as? MarkdownImageAttachment {
                output += attachment.markdownSource
            } else {
                output += ns.substring(with: effective)
            }
            display = NSMaxRange(effective)
        }
        return output
    }

    static func sourceOffset(forDisplayOffset offset: Int, in storage: NSAttributedString) -> Int {
        var source = 0
        var display = 0
        let target = min(max(0, offset), storage.length)
        while display < target {
            var effective = NSRange(location: display, length: 0)
            if let attachment = storage.attribute(.attachment, at: display,
                                                  effectiveRange: &effective) as? MarkdownImageAttachment {
                source += (attachment.markdownSource as NSString).length
                display = min(NSMaxRange(effective), target)
            } else {
                let consumed = min(effective.length, target - display)
                source += consumed
                display += consumed
            }
        }
        return source
    }

    static func displayOffset(forSourceOffset offset: Int, in storage: NSAttributedString) -> Int {
        var source = 0
        var display = 0
        let target = max(0, offset)
        while display < storage.length && source < target {
            var effective = NSRange(location: display, length: 0)
            if let attachment = storage.attribute(.attachment, at: display,
                                                  effectiveRange: &effective) as? MarkdownImageAttachment {
                let sourceLength = (attachment.markdownSource as NSString).length
                if source + sourceLength > target { return display }
                source += sourceLength
                display = NSMaxRange(effective)
            } else {
                let consumed = min(effective.length, target - source)
                source += consumed
                display += consumed
            }
        }
        return display
    }
}

struct LiveMarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let documentID: String?
    let baseURL: URL?
    let onPasteImage: (NSImage) -> String?
    let formatCommand: MarkdownFormatCommand?
    let onSelectionFormatsChanged: (Set<MarkdownFormatStyle>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let editor = MarkdownTextView()
        editor.imagePasteHandler = { image in
            guard let markdown = context.coordinator.parent.onPasteImage(image) else { return nil }
            return markdown
        }
        editor.delegate = context.coordinator
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindPanel = true
        editor.isIncrementalSearchingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 20, height: 18)
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = editor

        context.coordinator.editor = editor
        context.coordinator.render(text, baseURL: baseURL, preservingSelection: false)
        context.coordinator.lastDocumentID = documentID
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let documentChanged = context.coordinator.lastDocumentID != documentID
        if let command = formatCommand, command.id != context.coordinator.lastFormatCommandID {
            context.coordinator.lastFormatCommandID = command.id
            (scroll.documentView as? MarkdownTextView)?.applyFormat(command.style)
        }
        guard documentChanged || context.coordinator.lastSource != text || context.coordinator.lastBaseURL != baseURL else { return }
        context.coordinator.render(text, baseURL: baseURL, preservingSelection: !documentChanged)
        context.coordinator.lastDocumentID = documentID
        if documentChanged {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveMarkdownEditor
        weak var editor: NSTextView?
        var isRendering = false
        var lastSource = ""
        var lastBaseURL: URL?
        var lastDocumentID: String?
        var lastFormatCommandID: UUID?
        var pendingEditedRange: NSRange?
        var imageCache: [String: NSImage] = [:]

        init(_ parent: LiveMarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isRendering, let editor else { return }
            guard !editor.hasMarkedText() else { return }
            let storage = editor.textStorage ?? NSTextStorage()
            let source = markdownSource(from: storage)
            let displaySelection = editor.selectedRange()
            let sourceStart = sourceOffset(forDisplayOffset: displaySelection.location, in: storage)
            let sourceEnd = sourceOffset(forDisplayOffset: NSMaxRange(displaySelection), in: storage)
            let sourceSelection = NSRange(location: sourceStart, length: max(0, sourceEnd - sourceStart))
            lastSource = source
            parent.text = source
            render(source, baseURL: parent.baseURL, preservingSelection: false, sourceSelection: sourceSelection)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            pendingEditedRange = NSRange(location: affectedCharRange.location,
                                         length: (replacementString as NSString?)?.length ?? 0)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isRendering, let editor, editor.window?.firstResponder === editor else { return }
            let formats = (editor as? MarkdownTextView)?.currentFormats() ?? []
            Task { @MainActor [weak self] in self?.parent.onSelectionFormatsChanged(formats) }
        }

        func render(_ source: String, baseURL: URL?, preservingSelection: Bool, sourceSelection suppliedSelection: NSRange? = nil) {
            guard let editor else { return }
            let shouldPreserveViewport = preservingSelection || suppliedSelection != nil
            let clipView = shouldPreserveViewport ? editor.enclosingScrollView?.contentView : nil
            let visibleOrigin = clipView?.bounds.origin
            let caretViewportY = clipView.flatMap { clip in
                caretDocumentY(in: editor, at: editor.selectedRange().location).map { $0 - clip.bounds.origin.y }
            }
            let selectionAffinity = editor.selectionAffinity
            let sourceSelection: NSRange
            if let suppliedSelection {
                sourceSelection = suppliedSelection
            } else if preservingSelection {
                let storage = editor.textStorage ?? NSTextStorage()
                let displaySelection = editor.selectedRange()
                let start = sourceOffset(forDisplayOffset: displaySelection.location, in: storage)
                let end = sourceOffset(forDisplayOffset: NSMaxRange(displaySelection), in: storage)
                sourceSelection = NSRange(location: start, length: max(0, end - start))
            } else {
                sourceSelection = NSRange(location: 0, length: 0)
            }

            isRendering = true
            let rendered = makeAttributedMarkdown(source, baseURL: baseURL, cursor: sourceSelection.location)
            applyRenderedText(rendered, to: editor)
            let displayStart = displayOffset(forSourceOffset: sourceSelection.location, in: rendered)
            let displayEnd = displayOffset(forSourceOffset: NSMaxRange(sourceSelection), in: rendered)
            editor.setSelectedRange(
                NSRange(location: min(displayStart, rendered.length),
                        length: max(0, min(displayEnd, rendered.length) - min(displayStart, rendered.length))),
                affinity: selectionAffinity,
                stillSelecting: false
            )
            restoreViewport(origin: visibleOrigin, caretViewportY: caretViewportY,
                            in: clipView, editor: editor)
            isRendering = false
            pendingEditedRange = nil
            lastSource = source
            lastBaseURL = baseURL
        }

        private func applyRenderedText(_ rendered: NSAttributedString, to editor: NSTextView) {
            guard let storage = editor.textStorage else { return }
            guard storage.length == rendered.length, storage.string == rendered.string else {
                storage.setAttributedString(rendered)
                return
            }

            let range: NSRange
            if let pendingEditedRange {
                let safeLocation = min(pendingEditedRange.location, rendered.length)
                let safeLength = min(pendingEditedRange.length, rendered.length - safeLocation)
                range = (rendered.string as NSString).lineRange(
                    for: NSRange(location: safeLocation, length: safeLength)
                )
            } else {
                range = NSRange(location: 0, length: rendered.length)
            }
            guard range.length > 0 else { return }

            storage.beginEditing()
            storage.setAttributes([:], range: range)
            rendered.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
                storage.setAttributes(attributes, range: effectiveRange)
            }
            storage.endEditing()
        }

        private func restoreViewport(origin: NSPoint?, caretViewportY: CGFloat?,
                                     in clipView: NSClipView?, editor: NSTextView) {
            guard let origin, let clipView else { return }

            // Replacing the complete attributed string invalidates layout. Force that
            // layout now, then put the clip view back where the native edit left it.
            // This prevents selection restoration from scrolling the document again.
            if let textContainer = editor.textContainer {
                editor.layoutManager?.ensureLayout(for: textContainer)
            }
            editor.layoutSubtreeIfNeeded()
            var bounds = clipView.bounds
            bounds.origin = origin
            if let caretViewportY,
               let newCaretY = caretDocumentY(in: editor, at: editor.selectedRange().location) {
                bounds.origin.y = newCaretY - caretViewportY
            }
            let constrained = clipView.constrainBoundsRect(bounds)
            clipView.scroll(to: constrained.origin)
            editor.enclosingScrollView?.reflectScrolledClipView(clipView)
        }

        private func caretDocumentY(in editor: NSTextView, at location: Int) -> CGFloat? {
            guard let storage = editor.textStorage,
                  let layoutManager = editor.layoutManager,
                  editor.textContainer != nil else { return nil }
            guard storage.length > 0 else { return editor.textContainerOrigin.y }
            let character = min(max(0, location), storage.length - 1)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: character, length: 1))
            if location >= storage.length,
               layoutManager.extraLineFragmentTextContainer != nil {
                return editor.textContainerOrigin.y + layoutManager.extraLineFragmentRect.minY
            }
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return editor.textContainerOrigin.y + line.minY
        }

        private func makeAttributedMarkdown(_ source: String, baseURL: URL?, cursor: Int) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(string: source)
            let fullRange = NSRange(location: 0, length: result.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 5
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ], range: fullRange)

            styleFrontMatter(in: result)
            styleLines(in: result, cursor: cursor)
            styleInlinePatterns(in: result, cursor: cursor)
            replaceImages(in: result, baseURL: baseURL)
            return result
        }

        private func styleFrontMatter(in text: NSMutableAttributedString) {
            let source = text.string as NSString
            guard source.hasPrefix("---\n") else { return }
            let rest = NSRange(location: 4, length: max(0, source.length - 4))
            let closing = source.range(of: "\n---", options: [], range: rest)
            guard closing.location != NSNotFound else { return }
            let range = NSRange(location: 0, length: closing.location + closing.length)
            text.addAttributes([
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
                .kern: -0.1
            ], range: range)
        }

        private func styleLines(in text: NSMutableAttributedString, cursor: Int) {
            let source = text.string as NSString
            var location = 0
            while location < source.length {
                let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
                let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let visibleLength = (line as NSString).length
                let visibleRange = NSRange(location: lineRange.location, length: visibleLength)

                if line.hasPrefix("### ") {
                    styleHeading(in: text, range: visibleRange, markerLength: 4, size: 18, cursor: cursor)
                } else if line.hasPrefix("## ") {
                    styleHeading(in: text, range: visibleRange, markerLength: 3, size: 22, cursor: cursor)
                } else if line.hasPrefix("# ") {
                    styleHeading(in: text, range: visibleRange, markerLength: 2, size: 29, cursor: cursor)
                } else if line.hasPrefix("> ") {
                    text.addAttributes([.foregroundColor: NSColor.secondaryLabelColor,
                                        .font: NSFont.systemFont(ofSize: 16).italic], range: visibleRange)
                    text.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: lineRange.location, length: min(2, visibleLength)))
                } else if let match = firstMatch(#"^(\s*)[-*+]\s+(\[[ xX]\])(\s+)"#, in: line) {
                    styleTaskList(in: text, lineRange: visibleRange, match: match)
                } else if let match = firstMatch(#"^(\s*)([-*+])(\s+)"#, in: line) {
                    styleBulletList(in: text, lineRange: visibleRange, match: match)
                } else if let match = firstMatch(#"^(\s*)(\d+[.)])(\s+)"#, in: line) {
                    styleNumberedList(in: text, lineRange: visibleRange, match: match)
                } else if line == "---" || line == "***" || line == "___" {
                    text.addAttributes([.foregroundColor: NSColor.separatorColor,
                                        .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: visibleRange)
                }
                location = NSMaxRange(lineRange)
            }
        }

        private func firstMatch(_ pattern: String, in line: String) -> NSTextCheckingResult? {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        }

        private func listParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 5
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + 26
            return paragraph
        }

        private func styleBulletList(in text: NSMutableAttributedString, lineRange: NSRange,
                                     match: NSTextCheckingResult) {
            let marker = match.range(at: 2)
            let whitespace = match.range(at: 3)
            let globalMarker = NSRange(location: lineRange.location + marker.location, length: marker.length)
            let globalWhitespace = NSRange(location: lineRange.location + whitespace.location, length: whitespace.length)
            let font = NSFont.systemFont(ofSize: 16)
            let sourceMarker = (text.string as NSString).substring(with: globalMarker)
            if let bullet = NSGlyphInfo(glyphName: "bullet", for: font, baseString: sourceMarker) {
                text.addAttributes([.glyphInfo: bullet, .foregroundColor: NSColor.systemOrange], range: globalMarker)
            } else {
                text.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: globalMarker)
            }
            text.addAttributes([.font: font, .kern: 0], range: globalWhitespace)
            text.addAttribute(.paragraphStyle, value: listParagraphStyle(indent: CGFloat(match.range(at: 1).length) * 8),
                              range: lineRange)
        }

        private func styleNumberedList(in text: NSMutableAttributedString, lineRange: NSRange,
                                       match: NSTextCheckingResult) {
            let marker = match.range(at: 2)
            let whitespace = match.range(at: 3)
            let globalMarker = NSRange(location: lineRange.location + marker.location, length: marker.length)
            let globalWhitespace = NSRange(location: lineRange.location + whitespace.location, length: whitespace.length)
            text.addAttributes([.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold),
                                .foregroundColor: NSColor.systemOrange], range: globalMarker)
            text.addAttributes([.font: NSFont.systemFont(ofSize: 16), .kern: 0], range: globalWhitespace)
            text.addAttribute(.paragraphStyle, value: listParagraphStyle(indent: CGFloat(match.range(at: 1).length) * 8),
                              range: lineRange)
        }

        private func styleTaskList(in text: NSMutableAttributedString, lineRange: NSRange,
                                   match: NSTextCheckingResult) {
            let checkbox = match.range(at: 2)
            let whitespace = match.range(at: 3)
            let globalCheckbox = NSRange(location: lineRange.location + checkbox.location, length: checkbox.length)
            let globalWhitespace = NSRange(location: lineRange.location + whitespace.location, length: whitespace.length)
            let checked = (text.string as NSString).substring(with: globalCheckbox).lowercased() == "[x]"
            text.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: checked ? NSColor.systemGreen : NSColor.systemOrange
            ], range: globalCheckbox)
            text.addAttributes([.font: NSFont.systemFont(ofSize: 16), .kern: 0], range: globalWhitespace)
            text.addAttribute(.paragraphStyle,
                              value: listParagraphStyle(indent: CGFloat(match.range(at: 1).length) * 8),
                              range: lineRange)
        }

        private func styleHeading(in text: NSMutableAttributedString, range: NSRange, markerLength: Int, size: CGFloat, cursor: Int) {
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
            let marker = NSRange(location: range.location, length: min(markerLength, range.length))
            styleMarker(in: text, marker: marker, activeRange: range, cursor: cursor)
        }

        private func styleInlinePatterns(in text: NSMutableAttributedString, cursor: Int) {
            apply(pattern: #"\*\*\*([^\n*]+)\*\*\*"#, to: text) { whole, inner in
                let bold = NSFont.systemFont(ofSize: 16, weight: .bold)
                text.addAttribute(.font, value: NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask), range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"\*\*([^\n*]+)\*\*"#, to: text) { whole, inner in
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: 16, weight: .bold), range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"__([^\n_]+)__"#, to: text) { whole, inner in
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: 16, weight: .bold), range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"(?<!\*)\*([^\n*]+)\*(?!\*)"#, to: text) { whole, inner in
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: 16).italic, range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"(?<!_)_([^\n_]+)_(?!_)"#, to: text) { whole, inner in
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: 16).italic, range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"~~([^\n~]+)~~"#, to: text) { whole, inner in
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"==([^\n=]+)=="#, to: text) { whole, inner in
                text.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.32), range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"<u>([^\n]+)</u>"#, to: text) { whole, inner in
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            apply(pattern: #"`([^\n`]+)`"#, to: text) { whole, inner in
                text.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18)], range: inner)
                self.styleMarkers(in: text, whole: whole, inner: inner, cursor: cursor)
            }
            styleLinks(in: text, cursor: cursor)
        }

        private func apply(pattern: String, to text: NSMutableAttributedString, styling: (NSRange, NSRange) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: text.length)
            for match in regex.matches(in: text.string, range: range) where match.numberOfRanges > 1 {
                styling(match.range(at: 0), match.range(at: 1))
            }
        }

        private func styleMarkers(in text: NSMutableAttributedString, whole: NSRange, inner: NSRange, cursor: Int) {
            guard inner.location != NSNotFound else { return }
            let before = NSRange(location: whole.location, length: inner.location - whole.location)
            let afterStart = NSMaxRange(inner)
            let after = NSRange(location: afterStart, length: NSMaxRange(whole) - afterStart)
            styleMarker(in: text, marker: before, activeRange: whole, cursor: cursor)
            styleMarker(in: text, marker: after, activeRange: whole, cursor: cursor)
        }

        private func styleMarker(in text: NSMutableAttributedString, marker: NSRange, activeRange: NSRange, cursor: Int) {
            guard marker.length > 0 else { return }
            // Keep delimiter metrics independent from the caret. Expanding hidden
            // markers around it reflows wrapped lines and makes selections jump.
            text.addAttributes([.font: NSFont.systemFont(ofSize: 0.1),
                                .foregroundColor: NSColor.clear,
                                .kern: -0.1], range: marker)
        }

        private func styleLinks(in text: NSMutableAttributedString, cursor: Int) {
            guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^\)]+)\)"#) else { return }
            let matches = regex.matches(in: text.string, range: NSRange(location: 0, length: text.length))
            for match in matches {
                let whole = match.range(at: 0)
                let label = match.range(at: 1)
                text.addAttributes([.foregroundColor: NSColor.linkColor,
                                    .underlineStyle: NSUnderlineStyle.single.rawValue], range: label)
                let opening = NSRange(location: whole.location, length: label.location - whole.location)
                let tail = NSRange(location: NSMaxRange(label), length: NSMaxRange(whole) - NSMaxRange(label))
                styleMarker(in: text, marker: opening, activeRange: NSRange(location: NSMaxRange(whole) + 1, length: 0), cursor: cursor)
                styleMarker(in: text, marker: tail, activeRange: NSRange(location: NSMaxRange(whole) + 1, length: 0), cursor: cursor)
            }
        }

        private func replaceImages(in text: NSMutableAttributedString, baseURL: URL?) {
            guard let baseURL,
                  let regex = try? NSRegularExpression(pattern: #"(?m)^!\[([^\]]*)\]\(([^\)]+)\)[ \t]*$"#) else { return }
            let matches = regex.matches(in: text.string, range: NSRange(location: 0, length: text.length))
            for match in matches.reversed() {
                let ns = text.string as NSString
                let alt = ns.substring(with: match.range(at: 1))
                let encodedPath = ns.substring(with: match.range(at: 2))
                guard let path = encodedPath.removingPercentEncoding else { continue }
                let imageURL = baseURL.appendingPathComponent(path)
                let values = try? imageURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let cacheKey = "\(imageURL.standardizedFileURL.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)|\(alt)"
                let image: NSImage
                if let cached = imageCache[cacheKey] {
                    image = cached
                } else {
                    guard let loaded = NSImage(contentsOf: imageURL) else { continue }
                    let scaledImage = scaled(loaded)
                    image = alt.isEmpty ? scaledImage : imageWithCaption(scaledImage, caption: alt)
                    imageCache[cacheKey] = image
                }
                let markdown = ns.substring(with: match.range(at: 0))
                let attachment = MarkdownImageAttachment(markdownSource: markdown, image: image)
                let replacement = NSMutableAttributedString(attachment: attachment)
                text.replaceCharacters(in: match.range(at: 0), with: replacement)
            }
        }

        private func imageWithCaption(_ image: NSImage, caption: String) -> NSImage {
            let captionHeight: CGFloat = 24
            let output = NSImage(size: NSSize(width: image.size.width,
                                              height: image.size.height + captionHeight))
            output.lockFocus()
            image.draw(in: NSRect(x: 0, y: captionHeight,
                                  width: image.size.width, height: image.size.height))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (caption as NSString).draw(
                in: NSRect(x: 0, y: 4, width: image.size.width, height: captionHeight - 4),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ]
            )
            output.unlockFocus()
            return output
        }

        private func scaled(_ image: NSImage) -> NSImage {
            let maximum = NSSize(width: 460, height: 340)
            let scale = min(1, maximum.width / max(image.size.width, 1), maximum.height / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let output = NSImage(size: size)
            output.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size))
            output.unlockFocus()
            return output
        }

        private func markdownSource(from storage: NSTextStorage) -> String {
            MarkdownStorageCodec.source(from: storage)
        }

        private func sourceOffset(forDisplayOffset offset: Int, in storage: NSTextStorage) -> Int {
            MarkdownStorageCodec.sourceOffset(forDisplayOffset: offset, in: storage)
        }

        private func displayOffset(forSourceOffset offset: Int, in storage: NSAttributedString) -> Int {
            MarkdownStorageCodec.displayOffset(forSourceOffset: offset, in: storage)
        }
    }
}

private final class MarkdownTextView: NSTextView {
    var imagePasteHandler: ((NSImage) -> String?)?

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard range.length > 0,
              let delimiter = insertString as? String,
              ["*", "_", "~", "=", "`"].contains(delimiter) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard !containsAttachment(in: range) else {
            NSSound.beep()
            return
        }

        let selected = (string as NSString).substring(with: range)
        super.insertText(delimiter + selected + delimiter, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + (delimiter as NSString).length,
                                 length: (selected as NSString).length))
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let pastedImage = NSImage(pasteboard: pasteboard) ?? imageFromCopiedFile(in: pasteboard)
        if let image = pastedImage,
           let markdown = imagePasteHandler?(image) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": applyFormat(.bold); return true
            case "i": applyFormat(.italic); return true
            case "u": applyFormat(.underline); return true
            default: break
            }
        }
        if modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "7": applyFormat(.numberedList); return true
            case "8": applyFormat(.bulletList); return true
            case "h": applyFormat(.highlight); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    func currentFormats() -> Set<MarkdownFormatStyle> {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let selection = selectedRange()
        let location = min(selection.location, storage.length - 1)
        var formats: Set<MarkdownFormatStyle> = []
        let attributes = storage.attributes(at: location, effectiveRange: nil)
        if let font = attributes[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { formats.insert(.bold) }
            if traits.contains(.italicFontMask) { formats.insert(.italic) }
        }
        if (attributes[.underlineStyle] as? Int ?? 0) != 0 { formats.insert(.underline) }
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { formats.insert(.strikethrough) }
        if attributes[.backgroundColor] != nil { formats.insert(.highlight) }

        let ns = string as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: location, length: 0)))
        if line.range(of: #"^\s*[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) != nil {
            formats.insert(.taskList)
        } else if line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) != nil {
            formats.insert(.bulletList)
        } else if line.range(of: #"^\s*\d+[.)]\s+"#, options: .regularExpression) != nil {
            formats.insert(.numberedList)
        }
        return formats
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageFromCopiedFile(in: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = NSImage(pasteboard: sender.draggingPasteboard)
                ?? imageFromCopiedFile(in: sender.draggingPasteboard),
              let markdown = imagePasteHandler?(image) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        insertText(markdown, replacementRange: selectedRange())
        return true
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0 else { super.insertNewline(sender); return }
        let source = string as NSString
        let lineRange = source.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefixLength = max(0, selection.location - lineRange.location)
        let beforeCursor = source.substring(with: NSRange(location: lineRange.location, length: prefixLength))

        if let match = firstLineMatch(#"^(\s*)[-*+]\s+\[[ xX]\]\s+(.*)$"#, in: beforeCursor) {
            let indentation = (beforeCursor as NSString).substring(with: match.range(at: 1))
            let body = (beforeCursor as NSString).substring(with: match.range(at: 2))
            continueList(indentation: indentation, marker: "- [ ]", body: body, lineRange: lineRange,
                         beforeCursorLength: prefixLength)
            return
        }
        if let match = firstLineMatch(#"^(\s*)([-*+])\s+(.*)$"#, in: beforeCursor) {
            let indentation = (beforeCursor as NSString).substring(with: match.range(at: 1))
            let marker = (beforeCursor as NSString).substring(with: match.range(at: 2))
            let body = (beforeCursor as NSString).substring(with: match.range(at: 3))
            continueList(indentation: indentation, marker: marker, body: body, lineRange: lineRange,
                         beforeCursorLength: prefixLength)
            return
        }
        if let match = firstLineMatch(#"^(\s*)(\d+)([.)])\s+(.*)$"#, in: beforeCursor) {
            let indentation = (beforeCursor as NSString).substring(with: match.range(at: 1))
            let numberText = (beforeCursor as NSString).substring(with: match.range(at: 2))
            let punctuation = (beforeCursor as NSString).substring(with: match.range(at: 3))
            let body = (beforeCursor as NSString).substring(with: match.range(at: 4))
            let next = (Int(numberText) ?? 0) + 1
            continueList(indentation: indentation, marker: "\(next)\(punctuation)", body: body,
                         lineRange: lineRange, beforeCursorLength: prefixLength)
            return
        }
        super.insertNewline(sender)
    }

    private func firstLineMatch(_ pattern: String, in line: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private func continueList(indentation: String, marker: String, body: String,
                              lineRange: NSRange, beforeCursorLength: Int) {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText("", replacementRange: NSRange(location: lineRange.location, length: beforeCursorLength))
            super.insertNewline(nil)
        } else {
            insertText("\n\(indentation)\(marker) ", replacementRange: selectedRange())
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let formatItem = NSMenuItem(title: "Formato Markdown", action: nil, keyEquivalent: "")
        let formatMenu = NSMenu(title: "Formato Markdown")
        formatMenu.addItem(item("Título 1", #selector(formatHeading1)))
        formatMenu.addItem(item("Título 2", #selector(formatHeading2)))
        formatMenu.addItem(item("Título 3", #selector(formatHeading3)))
        formatMenu.addItem(item("Texto normal", #selector(formatBody)))
        formatMenu.addItem(.separator())
        formatMenu.addItem(item("Negrita", #selector(formatBold)))
        formatMenu.addItem(item("Cursiva", #selector(formatItalic)))
        formatMenu.addItem(item("Subrayado", #selector(formatUnderline)))
        formatMenu.addItem(item("Marcatextos", #selector(formatHighlight)))
        formatMenu.addItem(item("Tachado", #selector(formatStrikethrough)))
        formatMenu.addItem(.separator())
        formatMenu.addItem(item("Lista con viñetas", #selector(formatBulletList)))
        formatMenu.addItem(item("Lista numerada", #selector(formatNumberedList)))
        formatMenu.addItem(item("Lista de tareas", #selector(formatTaskList)))
        formatMenu.addItem(item("Enlace", #selector(formatLink)))
        formatMenu.addItem(item("Línea divisora", #selector(insertDivider)))
        formatItem.submenu = formatMenu
        menu.insertItem(formatItem, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    func applyFormat(_ style: MarkdownFormatStyle) {
        switch style {
        case .heading1: applyHeading(level: 1)
        case .heading2: applyHeading(level: 2)
        case .heading3: applyHeading(level: 3)
        case .body: applyHeading(level: 0)
        case .bold: toggleInline(opening: "**", closing: "**")
        case .italic: toggleInline(opening: "*", closing: "*")
        case .underline: toggleInline(opening: "<u>", closing: "</u>")
        case .highlight: toggleInline(opening: "==", closing: "==")
        case .strikethrough: toggleInline(opening: "~~", closing: "~~")
        case .bulletList: applyList(numbered: false)
        case .numberedList: applyList(numbered: true)
        case .taskList: applyTaskList()
        case .link: insertLink()
        case .divider: insertDivider(nil)
        }
        window?.makeFirstResponder(self)
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggleInline(opening: String, closing: String) {
        let selection = selectedRange()
        guard !containsAttachment(in: selection) else {
            NSSound.beep()
            return
        }
        let source = string as NSString
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length

        if selection.length == 0 {
            insertText(opening + closing, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + openingLength, length: 0))
            return
        }

        if let wrapped = enclosingMarkerRange(around: selection, opening: opening, closing: closing, in: source) {
            let inner = NSRange(location: wrapped.location + openingLength,
                                length: wrapped.length - openingLength - closingLength)
            let unwrapped = source.substring(with: inner)
            insertText(unwrapped, replacementRange: wrapped)
            setSelectedRange(NSRange(location: wrapped.location, length: (unwrapped as NSString).length))
        } else {
            let selected = source.substring(with: selection)
            insertText(opening + selected + closing, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + openingLength, length: selection.length))
        }
    }

    private func enclosingMarkerRange(around selection: NSRange, opening: String, closing: String,
                                      in source: NSString) -> NSRange? {
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length
        let selectionEnd = NSMaxRange(selection)
        let firstOpening = max(0, selection.location - openingLength)
        let firstClosing = max(0, selectionEnd - closingLength)
        var candidates: [NSRange] = []

        for openingStart in firstOpening...selection.location {
            guard openingStart + openingLength <= source.length,
                  source.substring(with: NSRange(location: openingStart, length: openingLength)) == opening else { continue }
            for closingStart in firstClosing...selectionEnd {
                guard closingStart >= openingStart + openingLength,
                      closingStart + closingLength <= source.length,
                      source.substring(with: NSRange(location: closingStart, length: closingLength)) == closing else { continue }
                let candidate = NSRange(location: openingStart,
                                        length: closingStart + closingLength - openingStart)
                guard candidate.location <= selection.location,
                      NSMaxRange(candidate) >= selectionEnd else { continue }
                candidates.append(candidate)
            }
        }
        return candidates.min { $0.length < $1.length }
    }

    private func applyHeading(level: Int) {
        let source = string as NSString
        let selection = selectedRange()
        let lineRange = source.lineRange(for: selection)
        guard !containsAttachment(in: lineRange) else {
            NSSound.beep()
            return
        }
        let original = source.substring(with: lineRange)
        let endsWithNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline, lines.last == "" { lines.removeLast() }
        let marker = level == 0 ? "" : String(repeating: "#", count: level) + " "
        lines = lines.map { line in
            let body = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            return body.isEmpty ? body : marker + body
        }
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        insertText(replacement, replacementRange: lineRange)
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private func applyList(numbered: Bool) {
        let source = string as NSString
        let selection = selectedRange()
        let lookupRange = selection.length > 0
            ? NSRange(location: selection.location, length: max(0, selection.length - 1))
            : selection
        let lineRange = source.lineRange(for: lookupRange)
        guard !containsAttachment(in: lineRange) else {
            NSSound.beep()
            return
        }
        let original = source.substring(with: lineRange)
        let endsWithNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline, lines.last == "" { lines.removeLast() }

        let targetPattern = numbered ? #"^\s*\d+[.)]\s+"# : #"^\s*[-*+]\s+"#
        let anyListPattern = #"^\s*(?:[-*+]|\d+[.)])\s+"#
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldRemove = !contentLines.isEmpty && contentLines.allSatisfy {
            $0.range(of: targetPattern, options: .regularExpression) != nil
        }

        var number = 1
        lines = lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
            let body = line.replacingOccurrences(of: anyListPattern, with: "", options: .regularExpression)
            if shouldRemove { return indentation + body }
            defer { number += 1 }
            return indentation + (numbered ? "\(number). " : "- ") + body
        }

        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        insertText(replacement, replacementRange: lineRange)
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private func applyTaskList() {
        let source = string as NSString
        let selection = selectedRange()
        let lookupRange = selection.length > 0
            ? NSRange(location: selection.location, length: max(0, selection.length - 1))
            : selection
        let lineRange = source.lineRange(for: lookupRange)
        guard !containsAttachment(in: lineRange) else {
            NSSound.beep()
            return
        }
        let original = source.substring(with: lineRange)
        let endsWithNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if endsWithNewline, lines.last == "" { lines.removeLast() }
        let pattern = #"^\s*[-*+]\s+\[[ xX]\]\s+"#
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let shouldRemove = !contentLines.isEmpty && contentLines.allSatisfy {
            $0.range(of: pattern, options: .regularExpression) != nil
        }
        lines = lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
            let body = line.replacingOccurrences(of: #"^\s*(?:(?:[-*+]\s+\[[ xX]\])|[-*+]|\d+[.)])\s+"#,
                                                 with: "", options: .regularExpression)
            return shouldRemove ? indentation + body : indentation + "- [ ] " + body
        }
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        insertText(replacement, replacementRange: lineRange)
        setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private func insertLink() {
        let selection = selectedRange()
        guard !containsAttachment(in: selection) else {
            NSSound.beep()
            return
        }
        let label = selection.length > 0 ? (string as NSString).substring(with: selection) : "texto"
        let replacement = "[\(label)](https://)"
        insertText(replacement, replacementRange: selection)
        let urlOffset = ("[\(label)](" as NSString).length
        setSelectedRange(NSRange(location: selection.location + urlOffset, length: 8))
    }

    @objc private func formatHeading1() { applyFormat(.heading1) }
    @objc private func formatHeading2() { applyFormat(.heading2) }
    @objc private func formatHeading3() { applyFormat(.heading3) }
    @objc private func formatBody() { applyFormat(.body) }
    @objc private func formatBold() { applyFormat(.bold) }
    @objc private func formatItalic() { applyFormat(.italic) }
    @objc private func formatUnderline() { applyFormat(.underline) }
    @objc private func formatHighlight() { applyFormat(.highlight) }
    @objc private func formatStrikethrough() { applyFormat(.strikethrough) }
    @objc private func formatBulletList() { applyFormat(.bulletList) }
    @objc private func formatNumberedList() { applyFormat(.numberedList) }
    @objc private func formatTaskList() { applyFormat(.taskList) }
    @objc private func formatLink() { applyFormat(.link) }

    @objc private func insertDivider(_ sender: Any?) {
        let selection = selectedRange()
        guard !containsAttachment(in: selection) else {
            NSSound.beep()
            return
        }
        let prefix = selection.location > 0 && !(string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)).contains("\n") ? "\n" : ""
        let divider = prefix + "\n---\n\n"
        insertText(divider, replacementRange: selection)
    }

    private func containsAttachment(in range: NSRange) -> Bool {
        guard range.length > 0, let storage = textStorage, storage.length > 0 else { return false }
        let safeLocation = min(range.location, storage.length)
        let safeLength = min(range.length, storage.length - safeLocation)
        guard safeLength > 0 else { return false }
        var found = false
        storage.enumerateAttribute(.attachment,
                                   in: NSRange(location: safeLocation, length: safeLength)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func imageFromCopiedFile(in pasteboard: NSPasteboard) -> NSImage? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let first = urls.first else { return nil }
        return NSImage(contentsOf: first)
    }
}

final class MarkdownImageAttachment: NSTextAttachment {
    let markdownSource: String

    init(markdownSource: String, image: NSImage) {
        self.markdownSource = markdownSource
        super.init(data: nil, ofType: nil)
        self.image = image
    }

    required init?(coder: NSCoder) {
        self.markdownSource = ""
        super.init(coder: coder)
    }
}

private extension NSFont {
    var italic: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
