import Foundation
import Testing
@testable import CombCore

@Suite("Buzz command responses")
struct CommandResponseTests {
    @Test("reads the channel id a DM command created")
    func readsChannelID() {
        let ok = #"response:{"channel_id":"9f2c-uuid","created":true}"#
        #expect(CommandResponse.channelID(in: ok) == "9f2c-uuid")
    }

    @Test("ignores an ordinary OK message")
    func ignoresPlainReason() {
        // Every other relay answers with a reason string, or nothing at all.
        // Neither is a failure, so neither may look like one.
        #expect(CommandResponse.channelID(in: "") == nil)
        #expect(CommandResponse.channelID(in: "duplicate: already have this event") == nil)
    }

    @Test("survives a malformed or unexpected payload")
    func survivesMalformed() {
        // A Buzz extension, so it is read defensively rather than trusted.
        #expect(CommandResponse.channelID(in: "response:") == nil)
        #expect(CommandResponse.channelID(in: "response:not json") == nil)
        #expect(CommandResponse.channelID(in: #"response:{"channel_id":""}"#) == nil)
        #expect(CommandResponse.channelID(in: #"response:{"other":"value"}"#) == nil)
        #expect(CommandResponse.channelID(in: #"response:{"channel_id":42}"#) == nil)
        #expect(CommandResponse.channelID(in: #"response:["a"]"#) == nil)
    }

    @Test("finds the payload after a leading reason")
    func findsAfterPrefix() {
        let ok = #"ok: response:{"channel_id":"abc"}"#
        #expect(CommandResponse.channelID(in: ok) == "abc")
    }
}
