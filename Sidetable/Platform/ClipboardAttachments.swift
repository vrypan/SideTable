import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Prefer copied text over image representations of that text. Finder file copies are attachments.
enum ClipboardAttachments {
    static func files(from pasteboard: NSPasteboard) throws -> [StagedFile] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let names = Set(urls.flatMap { [$0.path, $0.absoluteString, $0.lastPathComponent] })
        let textNamesFiles = !urls.isEmpty && text.split(whereSeparator: \.isNewline).allSatisfy { names.contains(String($0)) }
        if !text.isEmpty && !textNamesFiles { return [] }
        if !urls.isEmpty {
            return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { StagedFile(url: $0) }
        }
        guard let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return [] }
        guard bytes.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 64_000_000 / height else {
            throw ClipboardError.unreadableImage
        }
        let png: Data
        if CGImageSourceGetType(source) as String? == UTType.png.identifier { png = bytes }
        else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                  data.count <= 64 * 1024 * 1024 else { throw ClipboardError.unreadableImage }
            png = data
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SideTableClipboard").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("Screenshot.png")
        do { try png.write(to: file, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return [StagedFile(url: file, temporaryDirectory: directory)]
    }

    private enum ClipboardError: LocalizedError {
        case unreadableImage
        var errorDescription: String? { "The clipboard image could not be attached. Try a smaller image or save it as a file." }
    }
}
