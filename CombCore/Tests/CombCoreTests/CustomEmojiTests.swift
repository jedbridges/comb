import Foundation
import Testing
@testable import CombCore

@Suite("Custom emoji (NIP-30)")
struct CustomEmojiTests {
    private let party = CustomEmoji.Entry(
        shortcode: "party",
        url: "https://cdn.example/party.png"
    )

    @Test("reads shortcode and url out of an emoji tag")
    func readsEntries() {
        let entries = CustomEmoji.entries(in: [
            ["h", "room-1"],
            ["emoji", "party", "https://cdn.example/party.png"],
        ])
        #expect(entries == [party])
    }

    @Test("drops entries the renderer could not use")
    func dropsUnusable() {
        let entries = CustomEmoji.entries(in: [
            // No url.
            ["emoji", "lonely"],
            // Cleartext, which is a request made on the reader's behalf.
            ["emoji", "insecure", "http://cdn.example/a.png"],
            // A shortcode carrying a colon would match past its own delimiters.
            ["emoji", "bad:code", "https://cdn.example/b.png"],
            ["emoji", "has space", "https://cdn.example/c.png"],
        ])
        #expect(entries.isEmpty)
    }

    @Test("an inlined data image is allowed")
    func allowsDataURI() {
        // Same rule avatars follow: a `data:` image fetches nothing, so it
        // cannot become a request made on the reader's behalf.
        let entries = CustomEmoji.entries(in: [
            ["emoji", "inline", "data:image/png;base64,iVBORw0KGgo="],
        ])
        #expect(entries.map(\.shortcode) == ["inline"])
    }

    @Test("the first definition of a shortcode wins")
    func firstDefinitionWins() {
        // A second tag for the same shortcode cannot repoint an image the
        // reader has already been shown earlier in the same message.
        let entries = CustomEmoji.entries(in: [
            ["emoji", "party", "https://cdn.example/party.png"],
            ["emoji", "party", "https://cdn.example/other.png"],
        ])
        #expect(entries == [party])
    }

    @Test("splits content around a known shortcode")
    func tokenizes() {
        let tokens = CustomEmoji.tokenize("ship it :party: now", with: [party])
        #expect(tokens == [.text("ship it "), .emoji(party), .text(" now")])
    }

    @Test("an unknown shortcode stays literal text")
    func unknownStaysText() {
        let tokens = CustomEmoji.tokenize("ship it :nope: now", with: [party])
        #expect(tokens == [.text("ship it :nope: now")])
    }

    @Test("ordinary colons survive")
    func leavesProseAlone() {
        // Prose is full of colons, and eating them on the strength of markup
        // nobody wrote would mangle perfectly ordinary sentences.
        for text in ["the ratio is 3:2:1", "note: this is fine", "10:30 tomorrow"] {
            #expect(CustomEmoji.tokenize(text, with: [party]) == [.text(text)])
        }
    }

    @Test("a shortcode still resolves after an unmatched colon pair")
    func resumesAfterUnmatched() {
        // The scan restarts one character on rather than past the closing
        // colon, so the colon that opened a miss can still close a hit.
        let tokens = CustomEmoji.tokenize(":a::party:", with: [party])
        #expect(tokens == [.text(":a:"), .emoji(party)])
    }

    @Test("content with no definitions is one run of text")
    func noEntries() {
        #expect(CustomEmoji.tokenize(":party:", with: []) == [.text(":party:")])
        #expect(CustomEmoji.tokenize("", with: [party]).isEmpty)
    }

    @Test("a reaction that is only a shortcode is one emoji")
    func wholeReaction() {
        #expect(CustomEmoji.tokenize(":party:", with: [party]) == [.emoji(party)])
    }
}
