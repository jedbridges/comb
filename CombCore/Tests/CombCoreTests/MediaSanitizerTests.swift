import Foundation
import Testing
@testable import CombCore

@Suite("Media sanitizer")
struct MediaSanitizerTests {
    // MARK: - Builders

    /// A JPEG segment: marker, big-endian length covering itself, payload.
    private func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    private var canonicalJFIF: [UInt8] {
        // "JFIF\0", version, units, density, then zero thumbnail dimensions.
        [0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x02, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
    }

    /// A minimal but structurally valid JPEG, with whatever extra segments the
    /// caller wants inserted before the scan.
    private func jpeg(extra: [[UInt8]] = []) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += segment(0xE0, canonicalJFIF)
        for piece in extra { bytes += piece }
        bytes += segment(0xDB, [0x00] + Array(repeating: 0x10, count: 64))   // quant table
        bytes += segment(0xDA, [0x01, 0x01, 0x00, 0x00, 0x3F, 0x00])         // start of scan
        bytes += [0x12, 0x34, 0xFF, 0x00, 0x56]                              // entropy data
        bytes += [0xFF, 0xD9]                                                 // EOI
        return Data(bytes)
    }

    private func png(chunks: [(String, [UInt8])]) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        for (kind, payload) in chunks {
            let length = payload.count
            bytes += [
                UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
            ]
            bytes += Array(kind.utf8)
            bytes += payload
            bytes += [0, 0, 0, 0]   // CRC, not validated by the stripper
        }
        return Data(bytes)
    }

    private func markers(in data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        var found: [UInt8] = []
        var index = 2
        while index + 3 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            found.append(marker)
            if marker == 0xDA { break }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += 2 + length
        }
        return found
    }

    private func chunkKinds(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var kinds: [String] = []
        var index = 8
        while index + 12 <= bytes.count {
            let length =
                Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            kinds.append(String(decoding: bytes[index + 4..<index + 8], as: UTF8.self))
            index += 12 + length
        }
        return kinds
    }

    // MARK: - JPEG

    @Test("strips an EXIF segment")
    func stripsEXIF() throws {
        // The privacy case: EXIF from an iPhone routinely carries GPS.
        let exif = segment(0xE1, Array("Exif\0\0lat 51.5 lon -0.1".utf8))
        let cleaned = try #require(MediaSanitizer.strippedJPEG(jpeg(extra: [exif])))

        #expect(!markers(in: cleaned).contains(0xE1))
        #expect(!contains(cleaned, "lat 51.5"), "the coordinates must not survive")
    }

    @Test("strips an ICC colour profile")
    func stripsICC() throws {
        // ImageIO writes this into every JPEG it encodes, as APP2, and it is
        // what made a freshly re-encoded upload still fail with 422.
        let icc = segment(0xE2, Array("ICC_PROFILE\0".utf8) + Array(repeating: 0x01, count: 40))
        let cleaned = try #require(MediaSanitizer.strippedJPEG(jpeg(extra: [icc])))
        #expect(!markers(in: cleaned).contains(0xE2))
    }

    @Test("strips XMP and comments")
    func stripsXMPAndComments() throws {
        let xmp = segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8))
        let comment = segment(0xFE, Array("made with something".utf8))
        let cleaned = try #require(MediaSanitizer.strippedJPEG(jpeg(extra: [xmp, comment])))

        let kept = markers(in: cleaned)
        #expect(!kept.contains(0xE1))
        #expect(!kept.contains(0xFE))
    }

    @Test("keeps everything needed to decode the image")
    func keepsDecodingSegments() throws {
        let cleaned = try #require(MediaSanitizer.strippedJPEG(jpeg()))
        let kept = markers(in: cleaned)

        #expect(kept.contains(0xE0), "canonical JFIF header")
        #expect(kept.contains(0xDB), "quantisation table")
        #expect(kept.contains(0xDA), "start of scan")
        // The scan data and EOI have to survive or the file will not decode.
        #expect(cleaned.suffix(2) == Data([0xFF, 0xD9]))
    }

    @Test("drops a JFIF header carrying a thumbnail")
    func dropsThumbnailJFIF() throws {
        // A thumbnail is a second image smuggled inside the first, and the
        // relay computes the exact canonical length to forbid it.
        var withThumbnail = canonicalJFIF
        withThumbnail[12] = 1
        withThumbnail[13] = 1
        withThumbnail += [0xFF, 0x00, 0x00]

        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += segment(0xE0, withThumbnail)
        bytes += segment(0xDA, [0x01])
        bytes += [0xFF, 0xD9]

        let cleaned = try #require(MediaSanitizer.strippedJPEG(Data(bytes)))
        #expect(!markers(in: cleaned).contains(0xE0))
    }

    @Test("drops bytes trailing the end of image")
    func dropsTrailingBytes() throws {
        // The relay requires the file to end exactly at EOI; anything after it
        // is an obvious smuggling channel.
        var bytes = [UInt8](jpeg())
        bytes += Array("a secret appended after EOI".utf8)

        let cleaned = try #require(MediaSanitizer.strippedJPEG(Data(bytes)))
        #expect(cleaned.suffix(2) == Data([0xFF, 0xD9]))
        #expect(!contains(cleaned, "a secret"))
    }

    @Test("keeps entropy data containing a stuffed FF")
    func keepsStuffedBytes() throws {
        // 0xFF inside scan data is stuffed with 0x00. Mistaking it for a marker
        // would truncate the picture.
        let cleaned = try #require(MediaSanitizer.strippedJPEG(jpeg()))
        let bytes = [UInt8](cleaned)
        #expect(bytes.contains(0x12) && bytes.contains(0x56))
    }

    @Test("refuses bytes that are not a JPEG")
    func refusesNonJPEG() {
        #expect(MediaSanitizer.strippedJPEG(Data("not an image".utf8)) == nil)
        #expect(MediaSanitizer.strippedJPEG(Data()) == nil)
        #expect(MediaSanitizer.strippedJPEG(Data([0xFF, 0xD8])) == nil)
    }

    @Test("refuses a truncated segment rather than reading past the end")
    func refusesTruncated() {
        // A length field is attacker-controlled, so trusting it would read out
        // of bounds.
        let bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x01, 0x02]
        #expect(MediaSanitizer.strippedJPEG(Data(bytes)) == nil)
    }

    // MARK: - PNG

    @Test("strips text, EXIF and colour profile chunks")
    func stripsPNGMetadata() throws {
        let source = png(chunks: [
            ("IHDR", Array(repeating: 0, count: 13)),
            ("iCCP", Array("profile".utf8)),
            ("tEXt", Array("Author\0someone".utf8)),
            ("eXIf", Array("gps".utf8)),
            ("IDAT", [0x01, 0x02, 0x03]),
            ("IEND", []),
        ])

        let cleaned = try #require(MediaSanitizer.strippedPNG(source))
        #expect(chunkKinds(in: cleaned) == ["IHDR", "IDAT", "IEND"])
    }

    @Test("keeps rendering chunks")
    func keepsPNGRenderingChunks() throws {
        let source = png(chunks: [
            ("IHDR", Array(repeating: 0, count: 13)),
            ("sRGB", [0x00]),
            ("gAMA", [0x00, 0x00, 0xB1, 0x8F]),
            ("tRNS", [0xFF]),
            ("IDAT", [0x01]),
            ("IEND", []),
        ])

        let cleaned = try #require(MediaSanitizer.strippedPNG(source))
        #expect(chunkKinds(in: cleaned) == ["IHDR", "sRGB", "gAMA", "tRNS", "IDAT", "IEND"])
    }

    @Test("drops unknown ancillary chunks")
    func dropsUnknownAncillary() throws {
        // Unknown ancillary chunks are a private metadata channel. pHYs is
        // excluded deliberately even though it is well known.
        let source = png(chunks: [
            ("IHDR", Array(repeating: 0, count: 13)),
            ("pHYs", [0, 0, 0, 1, 0, 0, 0, 1, 1]),
            ("prVt", Array("anything".utf8)),
            ("IDAT", [0x01]),
            ("IEND", []),
        ])

        let cleaned = try #require(MediaSanitizer.strippedPNG(source))
        #expect(chunkKinds(in: cleaned) == ["IHDR", "IDAT", "IEND"])
    }

    @Test("stops exactly at IEND")
    func stopsAtIEND() throws {
        var bytes = [UInt8](png(chunks: [
            ("IHDR", Array(repeating: 0, count: 13)),
            ("IDAT", [0x01]),
            ("IEND", []),
        ]))
        bytes += Array("trailing".utf8)

        let cleaned = try #require(MediaSanitizer.strippedPNG(Data(bytes)))
        #expect(!contains(cleaned, "trailing"))
        #expect(chunkKinds(in: cleaned).last == "IEND")
    }

    @Test("refuses bytes that are not a PNG")
    func refusesNonPNG() {
        #expect(MediaSanitizer.strippedPNG(Data("not an image".utf8)) == nil)
        #expect(MediaSanitizer.strippedPNG(Data()) == nil)
    }

    @Test("refuses a chunk whose length runs past the end")
    func refusesOverlongChunk() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0x7F, 0xFF, 0xFF, 0xFF]
        bytes += Array("IDAT".utf8)
        bytes += [0x00, 0x00, 0x00, 0x00]
        #expect(MediaSanitizer.strippedPNG(Data(bytes)) == nil)
    }

    @Test("routes by declared type")
    func routesByType() {
        #expect(MediaSanitizer.stripped(jpeg(), mimeType: "image/jpeg") != nil)
        #expect(MediaSanitizer.stripped(jpeg(), mimeType: "image/gif") == nil)
    }

    private func contains(_ data: Data, _ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }
}
