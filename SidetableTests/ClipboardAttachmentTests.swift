import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Sidetable

@MainActor @Test func clipboardScreenshotsStageAndCleanUpWithoutSending() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    board.setData(png, forType: .png)
    var files = try ClipboardAttachments.files(from: board)
    #expect(files.count == 1)
    let url = try #require(files.first?.url)
    #expect(try Data(contentsOf: url) == png)
    files.removeAll()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    board.setString("Copied text", forType: .string)
    #expect(try ClipboardAttachments.files(from: board).isEmpty)
    board.clearContents(); board.setData(Data("invalid".utf8), forType: .png)
    #expect(throws: (any Error).self) { try ClipboardAttachments.files(from: board) }
}

@MainActor @Test func clipboardFileCopiesKeepOriginalsAndRejectDirectories() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("notes".utf8).write(to: file)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.writeObjects([file as NSURL])
    board.setString(file.path, forType: .string)
    var staged = try ClipboardAttachments.files(from: board)
    #expect(staged.count == 1)
    staged.removeAll()
    #expect(FileManager.default.fileExists(atPath: file.path))
    board.clearContents(); board.writeObjects([directory as NSURL])
    #expect(try ClipboardAttachments.files(from: board).isEmpty)
}

@MainActor @Test func attachmentPastePreservesExistingDraftAndSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("notes".utf8).write(to: file)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.writeObjects([file as NSURL])
    board.setString(file.path, forType: .string)

    for draft in ["", "Here is the file"] {
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.acceptsAttachments = true
        editor.string = draft
        let selection = NSRange(location: 0, length: (draft as NSString).length)
        editor.setSelectedRange(selection)
        var staged: [StagedFile] = []
        editor.pasteFiles = { staged.append(contentsOf: $0) }
        #expect(editor.readSelection(from: board, type: .string))
        #expect(staged.map(\.url) == [file])
        #expect(editor.string == draft)
        #expect(editor.selectedRange() == selection)
    }

    let editor = ComposerTextView()
    editor.isRichText = false
    editor.acceptsAttachments = true
    editor.setMarkedText("Draft in progress", selectedRange: NSRange(location: 17, length: 0),
        replacementRange: NSRange(location: 0, length: 0))
    #expect(editor.hasMarkedText())
    var staged: [StagedFile] = []
    editor.pasteFiles = { staged.append(contentsOf: $0) }
    #expect(editor.readSelection(from: board, type: .string))
    #expect(staged.map(\.url) == [file])
    #expect(editor.string == "Draft in progress")
    #expect(!editor.hasMarkedText())

    board.clearContents()
    board.setString(" plus text", forType: .string)
    #expect(editor.readSelection(from: board, type: .string))
    #expect(editor.string == "Draft in progress plus text")
    #expect(staged.count == 1)
}

@MainActor @Test func droppedFilesAttachAsTheyAreAndFoldersAreSkipped() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("notes".utf8).write(to: file)
    let providers = [NSItemProvider(contentsOf: file)!, NSItemProvider(contentsOf: directory)!]
    let staged = try await DroppedAttachments.files(from: providers)
    #expect(staged.map(\.url) == [file])
}

@MainActor @Test(arguments: ["Sunset", "photo.heic", "photo.jpg"]) func droppedImageDataKeepsItsFormatInATemporaryFile(name: String) async throws {
    let jpeg = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
        .representation(using: .jpeg, properties: [:]))
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
        completion(jpeg, nil); return nil
    }
    provider.suggestedName = name
    let staged = try await DroppedAttachments.files(from: [provider])
    let file = try #require(staged.first)
    #expect(staged.count == 1)
    #expect(file.name == (name == "Sunset" ? "Sunset.jpeg" : name == "photo.jpg" ? "photo.jpg" : "photo.jpeg"))
    #expect(UploadMediaPolicy.contentType(file.url) == "image/jpeg")
    #expect(try Data(contentsOf: file.url) == jpeg)
    #expect(DroppedAttachments.filename("../x/", type: .png) == "x.png")
    #expect(DroppedAttachments.filename(nil, type: .png) == "Image.png")
    #expect(DroppedAttachments.filename("photo.heic", type: .jpeg) == "photo.jpeg")
}

@MainActor @Test func plainTextDropsAreNotAttachments() async throws {
    let provider = NSItemProvider(object: "hello" as NSString)
    #expect(try await DroppedAttachments.files(from: [provider]).isEmpty)
}

@MainActor @Test func composerDropsUseTheSameAttachmentRules() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("notes.txt")
    try Data("notes".utf8).write(to: file)

    let files = NSPasteboard.withUniqueName()
    defer { files.releaseGlobally() }
    files.writeObjects([file as NSURL, directory as NSURL])
    #expect(DroppedAttachments.hasAttachments(files))
    #expect(try DroppedAttachments.files(from: files).map(\.url) == [file])

    // A browser image drag carries the image and its address; the image attaches.
    let image = NSPasteboard.withUniqueName()
    defer { image.releaseGlobally() }
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    image.declareTypes([NSPasteboard.PasteboardType(UTType.jpeg.identifier), .string], owner: nil)
    image.setData(jpeg, forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
    image.setString("https://example.com/a.jpg", forType: .string)
    #expect(DroppedAttachments.hasAttachments(image))
    let staged = try #require(try DroppedAttachments.files(from: image).first)
    #expect(staged.name == "Image.jpeg")
    #expect(try Data(contentsOf: staged.url) == jpeg)

    let text = NSPasteboard.withUniqueName()
    defer { text.releaseGlobally() }
    text.setString("hello", forType: .string)
    #expect(!DroppedAttachments.hasAttachments(text))

    let editor = ComposerTextView()
    #expect(!editor.acceptableDragTypes.contains(.fileURL))
    editor.acceptsAttachments = true
    #expect(editor.acceptableDragTypes.contains(.fileURL))
    #expect(editor.acceptableDragTypes.contains(NSPasteboard.PasteboardType(UTType.jpeg.identifier)))
}
