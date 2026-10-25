import Foundation
import Testing
import ApronCore
@testable import Sidetable

@Test func biosAreCurrentOnlyAndRespectExtMergingAndClears() {
    let recorded: JSONObject = ["user_id": .string("ada"), "ext": .object(["bio": .string("Historical bio")])]
    var store = RecordStore()
    #expect(UserProfile(recorded: recorded, store: store).bio == nil)
    store.mergeUser(["user_id": .string("ada"), "ext": .object(["bio": .string("Current bio"), "other": .string("kept")])], complete: true)
    #expect(UserProfile(recorded: recorded, store: store).bio == "Current bio")
    store.mergeUser(["user_id": .string("ada"), "ext": .object(["other": .string("updated")])])
    #expect(UserProfile(recorded: recorded, store: store).bio == "Current bio")
    store.mergeUser(["user_id": .string("ada"), "ext": .object(["bio": .string("")])])
    #expect(UserProfile(recorded: recorded, store: store).bio == nil)
    #expect(store.users["ada"]?.object("ext").string("other") == "updated")
    store.mergeUser(["user_id": .string("ada"), "ext": .object(["bio": .number(5)])])
    #expect(UserProfile(recorded: recorded, store: store).bio == nil)
    store.mergeUser(["user_id": .string("ada")], complete: true)
    #expect(UserProfile(recorded: recorded, store: store).bio == nil)
}

@Test func biosRemoveControlsAndCountUnicodeScalars() {
    #expect(ProfileBio.clean("  A\r\nB\rC\u{2028}D\u{2029}E\tF\u{0000}\u{0085}\u{202E}\u{2066}\n\n\n\nend  ") == "A\nB\nC\nD\nE F\n\nend")
    #expect(ProfileBio.characterCount("🦆") == 1)
    #expect(ProfileBio.characterCount("e\u{0301}") == 2)
    #expect(ProfileBio.characterCount(String(repeating: "🦆", count: 251)) == 251)
    #expect(ProfileBio.display(String(repeating: "🦆", count: 251)).unicodeScalars.count == 250)
    #expect(ProfileBio.display(" \n\t ").isEmpty)
}

@Test func bioLinksAreExplicitHTTPOnlyAndKeepPlainText() {
    let raw = "**literal** <b>text</b> @ada apron:?room=x www.example.com name@example.com https://vrypan.net http://example.com"
    let rendered = ProfileBio.linkedText(raw)
    #expect(String(rendered.characters) == raw)
    let links = rendered.runs.compactMap { $0.link?.absoluteString }
    #expect(links == ["https://vrypan.net", "http://example.com"])
    #expect(ProfileBio.linkedText("https://user:password@example.com").runs.compactMap { $0.link }.isEmpty)
}

@Test func biosRequireAdvertisedCapability() {
    var snapshot = SessionSnapshot()
    #expect(!ProfileBio.isSupported(by: snapshot))
    snapshot.server = ["capabilities": .array([.string("ext:bio")])]
    #expect(ProfileBio.isSupported(by: snapshot))
    snapshot.server = ["capabilities": .array([.string("ext")])]
    #expect(ProfileBio.isSupported(by: snapshot))
    snapshot.server = ["capabilities": .array([.string("ext:media")])]
    #expect(!ProfileBio.isSupported(by: snapshot))
}
