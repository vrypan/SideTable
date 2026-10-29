import AppKit
import ApronCore
import ImageIO
import UniformTypeIdentifiers

/// Local-only fixtures for screenshots and manual checks; no catalog or image requests leave the app.
@MainActor enum CustomEmojiPreview {
    static func install(on server: ServerModel) {
        guard let first = frame(color: NSColor(deviceRed: 0.56, green: 0.29, blue: 0.86, alpha: 1)), let second = frame(color: NSColor(deviceRed: 0.95, green: 0.48, blue: 0.1, alpha: 1)),
              let png = encode([first], type: UTType.png.identifier), let gif = encode([first, second], type: UTType.gif.identifier) else { return }
        let still = "data:image/png;base64," + png.base64EncodedString()
        let animation = "data:image/gif;base64," + gif.base64EncodedString()
        let catalog: JSONObject = [
            ":party:": .object(["url": .string(animation), "static_url": .string(still), "alt": .string("Party face"),
                                "category": .string("Team favorites"), "tags": .array([.string("celebrate"), .string("ship")])]),
            ":badge:": .object(["url": .string(still), "alt": .string("Team badge"), "category": .string("Team favorites")]),
            ":old_badge:": .object(["url": .string(still), "alt": .string("Retired team badge"), "hidden": .bool(true)])
        ]
        guard let data = try? JSONEncoder().encode(catalog) else { return }
        var frame = server.snapshot.server
        frame["capabilities"] = .array((frame.strings("capabilities") + ["ext:emoji"]).map(JSONValue.string))
        var ext = frame.object("ext")
        ext["emoji"] = .object(["catalog_url": .string("data:application/json;base64," + data.base64EncodedString())])
        frame["ext"] = .object(ext); server.snapshot.server = frame
        let id = "1900000000300"
        server.snapshot.store.installMessage([
            "message_id": .string(id), "log_id": .string(id), "room_id": .string("general"), "from": .object(["user_id": .string("maya")]),
            "body": .object(["format": .string("markdown"), "text": .string("""
                Shipped it! :party: Thanks @ada :badge:

                Adjacent keys: :badge::party: · Time prefix: 12:30:party:

                **Bold :badge:** and [a link :party:](https://example.com).

                Code stays literal: `:party:`. Missing: :unknown:. Hidden, still rendered: :old_badge:
                """)])])
        server.snapshot.store.reactions[RecordKey(id, "ada")] = ["emojis": .array([.string(":party:"), .string(":missing:"), .string("👍")])]
        server.snapshot.store.reactions[RecordKey(id, "ben")] = ["emojis": .array([.string(":party:")])]
        server.snapshot.store.rooms["general"]?["description"] = .string("A shared space for our team :badge:")
        Task { await server.emojis.prepare(keys: Set(catalog.keys), reduceMotion: false) }
    }
    private static func frame(color: NSColor) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        for x in 0..<48 {
            for y in 0..<48 {
                let inside = (x - 24) * (x - 24) + (y - 24) * (y - 24) < 23 * 23
                let eye = ((x - 16) * (x - 16) + (y - 17) * (y - 17) < 9) || ((x - 32) * (x - 32) + (y - 17) * (y - 17) < 9)
                let smile = y >= 30 && y <= 33 && x >= 15 && x <= 33
                bitmap.setColor(!inside ? NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0) : eye || smile ? NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1) : color, atX: x, y: y)
            }
        }
        return bitmap.cgImage
    }
    private static func encode(_ images: [CGImage], type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil) else { return nil }
        for image in images {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
