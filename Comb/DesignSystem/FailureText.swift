import Foundation

/// What Comb says when something did not work.
///
/// One place, because the same failure reaches the reader from more than one
/// screen: a reaction can fail from the timeline or from inside a thread, and
/// two files each holding their own copy of the sentence is how those two
/// screens start describing the same event differently.
///
/// The voice rule these follow, from the design brief: name what happened and
/// what it means for the reader, in the words they would use. Never apologise,
/// never exclaim. In particular, never say a thing "did not reach the
/// community" — a community is people, not an address, and inventing a soft
/// noun for the server is the protocol leaking under a friendlier name. Say
/// what the reader can observe: nobody else has it, the message is unchanged,
/// it is still there.
enum FailureText {
    static let reaction = "That reaction did not send."

    static let edit = "That edit did not send. The message still says what it said."

    static let deleteTitle = "That message could not be deleted"
    static let deleteBody = "It is still there, and people can still read it."

    static let reportSent = "Report sent."
    static let reportFailedButBlocked = "Blocked on this iPhone. The report could not be sent."
    /// No "try again" in the words: the button beside this notice says it.
    static let reportFailed = "The report could not be sent."

    static let nameUndelivered =
        "Saved on this iPhone, but nobody else has your new name yet. Press return to try again."
}
