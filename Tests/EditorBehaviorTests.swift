import AppKit

@main
struct EditorBehaviorTests {
    static func main() {
        let prefix = "Texto 🧘🏽‍♀️ con acentos: ā ī ū ñ "
        let suffix = "\nTexto posterior"
        let markdown = "![Imagen pegada](Recursos/imagen.png)"
        let rendered = NSMutableAttributedString(string: prefix)
        rendered.append(NSAttributedString(
            attachment: MarkdownImageAttachment(markdownSource: markdown,
                                                image: NSImage(size: NSSize(width: 10, height: 10)))
        ))
        rendered.append(NSAttributedString(string: suffix))

        let recovered = MarkdownStorageCodec.source(from: rendered)
        precondition(recovered == prefix + markdown + suffix,
                     "Rendered images and Unicode text must round-trip without duplicated captions or corruption")

        let imageDisplayOffset = (prefix as NSString).length
        let imageSourceEnd = imageDisplayOffset + (markdown as NSString).length
        precondition(MarkdownStorageCodec.sourceOffset(
            forDisplayOffset: imageDisplayOffset + 1, in: rendered
        ) == imageSourceEnd, "The position after an image must map after its complete Markdown source")
        precondition(MarkdownStorageCodec.displayOffset(
            forSourceOffset: imageSourceEnd, in: rendered
        ) == imageDisplayOffset + 1, "The Markdown position after an image must map after its attachment")

        print("Editor behavior tests passed")
    }
}
