import Foundation

/// Strips every metadata channel out of an encoded image.
///
/// Buzz relays refuse images that carry metadata at all
/// (`crates/buzz-media/src/validation.rs`): for JPEG, any APP segment other
/// than a canonical JFIF or Adobe header, plus comments; for PNG, `eXIf`,
/// `tEXt`, `iCCP` and any unrecognised ancillary chunk. Both formats must end
/// exactly at their terminator, with no trailing bytes.
///
/// Re-encoding an image is not enough on its own. ImageIO attaches an ICC
/// colour profile, which lands in a JPEG as an APP2 segment and in a PNG as
/// `iCCP`, and both are refused. So the bytes are filtered here rather than
/// left to whatever the encoder felt like emitting.
///
/// The privacy point stands regardless of what the relay enforces: EXIF from
/// an iPhone routinely carries GPS coordinates, and a chat client should not
/// publish where a photo was taken.
public enum MediaSanitizer {
    /// Removes metadata from an encoded image, choosing the filter by format.
    /// Returns nil if the bytes are not a JPEG or PNG this can parse.
    public static func stripped(_ data: Data, mimeType: String) -> Data? {
        switch mimeType {
        case "image/jpeg": strippedJPEG(data)
        case "image/png": strippedPNG(data)
        default: nil
        }
    }

    // MARK: - JPEG

    /// Keeps the frame, the scan, and a canonical JFIF header. Drops APP1
    /// through APP15 (EXIF, XMP, ICC, Photoshop) and comments.
    public static func strippedJPEG(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }

        var output: [UInt8] = [0xFF, 0xD8]
        var index = 2

        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }

            // Fill bytes: any number of 0xFF may pad a marker.
            var markerIndex = index + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { return nil }

            let marker = bytes[markerIndex]

            // Standalone markers carry no payload.
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                output.append(contentsOf: [0xFF, marker])
                index = markerIndex + 1
                continue
            }

            if marker == 0xD9 { break }   // EOI before any scan: no image data.

            guard markerIndex + 2 < bytes.count else { return nil }
            let length = Int(bytes[markerIndex + 1]) << 8 | Int(bytes[markerIndex + 2])
            guard length >= 2 else { return nil }

            let segmentEnd = markerIndex + 1 + length
            guard segmentEnd <= bytes.count else { return nil }

            if marker == 0xDA {
                // Start of scan: copy it and the entropy-coded data that
                // follows, up to and including EOI. A 0xFF inside that data is
                // always stuffed with 0x00 or is a restart marker, so an
                // unstuffed FF D9 is a genuine end of image.
                output.append(contentsOf: bytes[markerIndex - 1..<segmentEnd])
                var scan = segmentEnd
                while scan + 1 < bytes.count {
                    if bytes[scan] == 0xFF, bytes[scan + 1] == 0xD9 { break }
                    scan += 1
                }
                guard scan + 1 < bytes.count else { return nil }
                output.append(contentsOf: bytes[segmentEnd...scan + 1])
                // Anything after EOI is trailing junk and is dropped, which is
                // also what the relay demands.
                return Data(output)
            }

            if keepsSegment(marker: marker, payload: bytes[markerIndex + 3..<segmentEnd]) {
                output.append(contentsOf: bytes[markerIndex - 1..<segmentEnd])
            }
            index = segmentEnd
        }

        return nil
    }

    private static func keepsSegment(marker: UInt8, payload: ArraySlice<UInt8>) -> Bool {
        switch marker {
        case 0xE0:
            // A canonical JFIF header only, with no embedded thumbnail: the
            // relay computes the exact expected length from the thumbnail
            // dimensions and rejects anything else.
            let bytes = [UInt8](payload)
            return bytes.count == 14
                && bytes.prefix(5).elementsEqual([0x4A, 0x46, 0x49, 0x46, 0x00])
                && bytes[12] == 0 && bytes[13] == 0
        case 0xEE:
            let bytes = [UInt8](payload)
            return bytes.count == 12 && bytes.prefix(5).elementsEqual([0x41, 0x64, 0x6F, 0x62, 0x65])
        case 0xE1...0xED, 0xEF, 0xFE:
            // EXIF, XMP, ICC, Photoshop resources, comments.
            return false
        default:
            // Quantisation tables, Huffman tables, frame headers: all required
            // to decode the image.
            return true
        }
    }

    // MARK: - PNG

    /// Keeps critical chunks and the ancillary chunks that only affect
    /// rendering. Drops text, EXIF, colour profiles, and anything unknown.
    public static func strippedPNG(_ data: Data) -> Data? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data)
        guard bytes.count > signature.count, Array(bytes.prefix(8)) == signature else { return nil }

        var output = signature
        var index = signature.count

        while index + 12 <= bytes.count {
            let length =
                Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let kind = Array(bytes[index + 4..<index + 8])
            guard let end = chunkEnd(start: index, length: length, count: bytes.count)
            else { return nil }

            // Bit 5 of the first byte marks a chunk as ancillary, meaning a
            // decoder may ignore it. Those are the metadata channels.
            let isAncillary = kind[0] & 0x20 != 0
            if !isAncillary || allowedAncillary.contains(kind) {
                output.append(contentsOf: bytes[index..<end])
            }

            index = end
            if kind == Array("IEND".utf8) {
                // Stop exactly here: trailing bytes are refused.
                return Data(output)
            }
        }

        return nil
    }

    /// 4 length + 4 type + payload + 4 CRC, guarded against a declared length
    /// that would run past the end of the data.
    private static func chunkEnd(start: Int, length: Int, count: Int) -> Int? {
        guard length >= 0,
              let size = 12.addingReportingOverflowOrNil(length),
              let end = start.addingReportingOverflowOrNil(size),
              end <= count
        else { return nil }
        return end
    }

    /// Ancillary chunks that affect how the image renders, matching the relay's
    /// own allow list. `pHYs` is deliberately absent: arbitrary values there are
    /// an identity channel.
    private static let allowedAncillary: Set<[UInt8]> = Set(
        ["cHRM", "gAMA", "sBIT", "sRGB", "bKGD", "hIST", "tRNS", "sPLT", "acTL", "fcTL", "fdAT"]
            .map { Array($0.utf8) }
    )
}

extension Int {
    /// Addition that yields nil instead of trapping, for bounds arithmetic on
    /// lengths read out of untrusted files.
    func addingReportingOverflowOrNil(_ other: Int) -> Int? {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? nil : result
    }
}
