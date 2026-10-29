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

/// Dragged files attach as they are. Dragged image data (from a browser, Photos,
/// or Preview) is copied to a temporary file in its original format; text and
/// web links are not attachments.
enum DroppedAttachments {
    static let types: [UTType] = [.fileURL, .image]

    @MainActor static func files(from providers: [NSItemProvider]) async throws -> [StagedFile] {
        var files: [StagedFile] = []
        for provider in providers {
            if let file = try await file(from: provider) { files.append(file) }
        }
        return files
    }

    @MainActor private static func file(from provider: NSItemProvider) async throws -> StagedFile? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = try await withCheckedThrowingContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
                }
            }
            // Folders and other non-regular items cannot be uploaded.
            guard let url, url.isFileURL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            return StagedFile(url: url)
        }
        guard let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .image) }) else { return nil }
        let name = filename(provider.suggestedName, type: type)
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                // The source file is removed when this handler returns.
                guard let source else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                continuation.resume(with: Result { try copy(source, name: name) })
            }
        }
    }

    /// The same rules for a drag onto an AppKit view, such as the composer.
    static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || imageType(pasteboard) != nil
    }

    static func files(from pasteboard: NSPasteboard) throws -> [StagedFile] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { StagedFile(url: $0) }
        }
        guard let type = imageType(pasteboard), let utType = UTType(type.rawValue),
              let data = pasteboard.data(forType: type) else { return [] }
        return [try stage(name: filename(nil, type: utType)) { try data.write(to: $0, options: .atomic) }]
    }

    /// Image types dragged onto an AppKit view, in addition to file URLs.
    static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff] +
        [UTType.jpeg, .heic, .gif, .webP].map { NSPasteboard.PasteboardType($0.identifier) }

    private static func imageType(_ pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        pasteboard.types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
    }

    static func filename(_ suggested: String?, type: UTType) -> String {
        let base = ((suggested ?? "") as NSString).lastPathComponent
        let name = ["", ".", ".."].contains(base) ? "Image" : base
        guard let ext = type.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty else { return name }
        return name + "." + ext
    }

    static func copy(_ source: URL, name: String) throws -> StagedFile {
        try stage(name: name) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    private static func stage(name: String, write: (URL) throws -> Void) throws -> StagedFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SideTableDrops").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        do { try write(file) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return StagedFile(url: file, temporaryDirectory: directory)
    }
}
