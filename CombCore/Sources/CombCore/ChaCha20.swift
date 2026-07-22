import Foundation

/// Raw ChaCha20 (RFC 8439), keystream only.
///
/// Hand-rolled because NIP-44 needs unauthenticated ChaCha20 with its MAC
/// applied separately, and CryptoKit only exposes the ChaCha20-Poly1305 AEAD.
/// The cipher is a fixed 20-round ARX permutation with no branching on secret
/// data, which makes it one of the safer primitives to implement directly; it
/// is verified against the RFC's own vectors and NIP-44's.
enum ChaCha20 {
    /// XORs `data` with the keystream for (key, nonce), counter starting at 0.
    /// Encryption and decryption are the same operation.
    static func process(key: Data, nonce: Data, _ data: Data) -> Data {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")

        var out = Data(capacity: data.count)
        let input = [UInt8](data)
        var counter: UInt32 = 0
        var offset = 0

        while offset < input.count {
            let block = keystreamBlock(key: key, nonce: nonce, counter: counter)
            let remaining = min(64, input.count - offset)
            for index in 0..<remaining {
                out.append(input[offset + index] ^ block[index])
            }
            offset += 64
            counter &+= 1
        }
        return out
    }

    private static func keystreamBlock(key: Data, nonce: Data, counter: UInt32) -> [UInt8] {
        // "expand 32-byte k", the RFC's constants.
        var state: [UInt32] = [0x6170_7865, 0x3320_646E, 0x7962_2D32, 0x6B20_6574]
        state += littleEndianWords(key)
        state.append(counter)
        state += littleEndianWords(nonce)

        var working = state
        for _ in 0..<10 {
            // Column rounds.
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            // Diagonal rounds.
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        var block = [UInt8]()
        block.reserveCapacity(64)
        for index in 0..<16 {
            let word = working[index] &+ state[index]
            block.append(UInt8(truncatingIfNeeded: word))
            block.append(UInt8(truncatingIfNeeded: word >> 8))
            block.append(UInt8(truncatingIfNeeded: word >> 16))
            block.append(UInt8(truncatingIfNeeded: word >> 24))
        }
        return block
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]; state[d] = rotl(state[d] ^ state[a], 16)
        state[c] = state[c] &+ state[d]; state[b] = rotl(state[b] ^ state[c], 12)
        state[a] = state[a] &+ state[b]; state[d] = rotl(state[d] ^ state[a], 8)
        state[c] = state[c] &+ state[d]; state[b] = rotl(state[b] ^ state[c], 7)
    }

    private static func rotl(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static func littleEndianWords(_ data: Data) -> [UInt32] {
        // Built up in statements; the folded expression form sends the type
        // checker into the weeds.
        let bytes = [UInt8](data)
        var words: [UInt32] = []
        words.reserveCapacity(bytes.count / 4)
        var index = 0
        while index < bytes.count {
            var word = UInt32(bytes[index])
            word |= UInt32(bytes[index + 1]) << 8
            word |= UInt32(bytes[index + 2]) << 16
            word |= UInt32(bytes[index + 3]) << 24
            words.append(word)
            index += 4
        }
        return words
    }
}
