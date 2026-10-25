import AppKit
import Testing
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
