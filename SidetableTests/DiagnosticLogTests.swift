import Foundation
import Testing
@testable import Sidetable

@Test func diagnosticJournalRotatesAnonymizesAndKeepsRoomCorrelation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticLog(directory: directory, limit: 2048)
    let server = UUID()
    for index in 0..<80 {
        log.transcript(server: server, room: "private-room-id", offset: Double(index), viewportHeight: 400,
                       documentHeight: 1200, visibleRows: 3, atEnd: false)
    }
    let text = await log.snapshot()
    #expect(!text.contains("private-room-id") && !text.contains(server.uuidString))
    let entries = try text.split(separator: "\n").filter { $0.hasPrefix("{") }.map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    #expect(entries.count > 1 && entries.count < 80)
    #expect(Set(entries.compactMap { $0["room"] as? String }).count == 1)
    #expect(entries.last?["offset"] as? Double == 79)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 2)
    for file in files { #expect(try Data(contentsOf: file).count <= 2048) }
    let relaunched = DiagnosticLog(directory: directory, limit: 2048)
    #expect(await relaunched.snapshot() == text)
}

@Test func diagnosticJournalFallsBackToMemoryWhenDiskIsUnavailable() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let log = DiagnosticLog(directory: file)
    log.transcript(server: UUID(), room: "secret", offset: 0, viewportHeight: 400,
                   documentHeight: 0, visibleRows: 0, atEnd: true)
    let text = await log.snapshot()
    #expect(text.contains("Disk logging failed"))
    #expect(text.contains("\"visibleRows\":0") && !text.contains("secret"))
}
