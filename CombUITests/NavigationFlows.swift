import XCTest

/// The flows nothing else can check.
///
/// A navigation fix once shipped that made the bug it claimed to fix worse: it
/// called a parent's `DismissAction` through a closure, and a parent's dismiss
/// is inert while a child is pushed on top of it. It compiled. It was called.
/// It returned. The screen did not change. No compiler, no unit test and no
/// snapshot catches that, because every one of them agrees the code ran.
///
/// So these drive the real navigation stack in a real simulator and assert
/// where the reader actually ends up. They are slow and they are the only
/// thing that can answer this question, which is why they are a separate
/// target run on demand rather than part of the fast loop.
///
/// Everything runs in `--demo`: an in-memory store seeded at launch, no relay,
/// no network, no keychain identity. That is what makes the flows
/// deterministic without a server to arrange.
@MainActor
final class NavigationFlows: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        // `--no-tips` because a first-run tip is an inset that moves the rest of
        // the screen, and a suite that asserts on positions cannot also be the
        // first run. Without it two consecutive runs failed on two different
        // assertions, which is what a layout shift looks like from outside: not
        // one broken thing, a different one each time.
        app.launchArguments = ["--demo", "--no-tips"] + extraArguments
        app.launch()
        return app
    }

    /// The plain case, and the anchor for everything else: the demo seed puts
    /// channels on screen without a relay.
    func testDemoLaunchShowsChannels() {
        let app = launch()
        XCTAssertTrue(
            app.otherElements[A11y.channelList].waitForExistence(timeout: 20),
            "the demo seed should put a channel list on screen with no network at all"
        )
    }

    /// Settings is a sheet over the channel list, and tapping Done must
    /// actually take it away.
    ///
    /// The assertion that matters is that settings is gone. "The channel list
    /// is there" sounds like the same claim and is not one at all, because the
    /// list never leaves the tree while a sheet covers it.
    func testSettingsOpensAndClosesBackToTheChannelList() {
        let app = launch()
        XCTAssertTrue(app.otherElements[A11y.channelList].waitForExistence(timeout: 20))

        app.buttons[A11y.settingsButton].tap()

        // The screen's own identifier, not a section header. An earlier version
        // matched the text "Notifications", which made a copy edit capable of
        // turning the only load-bearing assertion in this suite red in a way
        // that reads as a navigation regression.
        let settings = app.descendants(matching: .any)
            .matching(identifier: A11y.settingsScreen)
            .firstMatch
        XCTAssertTrue(
            settings.waitForExistence(timeout: 10),
            "tapping the gear should actually present settings"
        )

        // Done, not a swipe. `dismiss()` is the exact mechanism the defect
        // behind this suite was about, so exercising it is the point; the
        // gesture was also starting inside a scrollable Form and only worked
        // because the form happened to be at scroll top.
        app.buttons[A11y.settingsDone].tap()

        // The one assertion that can tell a working dismiss from an inert one.
        //
        // Deliberately not paired with "the channel list exists": a sheet does
        // not remove what it covers from the accessibility tree, so that check
        // passes with settings still fully on screen. It was in this test, and
        // it was the assertion the commit message led with. A push does remove
        // the previous screen, which is why the equivalent line in the
        // channel-and-back flow below is real evidence and this one was not.
        XCTAssertTrue(
            settings.waitForNonExistence(timeout: 10),
            "settings should be gone, not merely covered"
        )
    }

    /// Opening a channel and coming back. The push and the pop are the two
    /// halves of the navigation stack that a dismiss bug lives between.
    func testOpeningAChannelAndGoingBack() {
        let app = launch()
        let list = app.otherElements[A11y.channelList]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", A11y.anyChannelRow))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "the demo seed should provide a channel")
        firstRow.tap()

        let compose = app.textViews[A11y.composeField].firstMatch
        let composeField = compose.exists ? compose : app.textFields[A11y.composeField].firstMatch
        XCTAssertTrue(
            composeField.waitForExistence(timeout: 10),
            "opening a channel should show somewhere to type"
        )

        // Named, not positional. `element(boundBy: 0)` happens to be the back
        // button today and stops being it the moment a leading toolbar item is
        // added to the channel screen.
        app.navigationBars.buttons["BackButton"].tap()

        // Real evidence here, unlike the sheet case above: a NavigationStack
        // push takes the previous screen out of the tree, so the list existing
        // again means the pop happened.
        XCTAssertTrue(
            list.waitForExistence(timeout: 10),
            "going back from a channel should land on the channel list"
        )
    }

    /// Typing and sending, end to end through the real compose bar.
    ///
    /// In demo mode the send is optimistic and local, so this asserts the
    /// message appears, not that a relay accepted it. That distinction is the
    /// contract suite's job.
    func testSendingAMessageShowsItInTheTimeline() {
        let app = launch("--open-first-channel")

        let compose = app.textViews[A11y.composeField].firstMatch
        let composeField = compose.exists ? compose : app.textFields[A11y.composeField].firstMatch
        XCTAssertTrue(
            composeField.waitForExistence(timeout: 20),
            "--open-first-channel should land straight in a channel"
        )

        let text = "sent by a ui test"
        composeField.tap()
        composeField.typeText(text)

        let send = app.buttons[A11y.sendButton]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        // Waited for rather than read straight after typing. `canSend` is
        // SwiftUI state behind an animation, so an immediate read passes on
        // timing rather than on the button being live.
        XCTAssertTrue(
            send.waitForEnabled(timeout: 5),
            "the send button should be live once there is something to send"
        )
        send.tap()

        // Matched on any element carrying the text rather than on a StaticText
        // with exactly that label. A message row composes author, body and
        // time, and how SwiftUI exposes that to accessibility is not something
        // this flow should be asserting: the question is whether what was sent
        // is on screen.
        let sent = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(
            sent.waitForExistence(timeout: 10),
            "a sent message should appear in the timeline"
        )
    }
}

extension XCUIElement {
    /// XCTest has `waitForExistence` and no equivalent for enablement, so a
    /// test that wants to know a control became live has to poll for it rather
    /// than read the property and hope the state has settled.
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let becameEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: self
        )
        return XCTWaiter().wait(for: [becameEnabled], timeout: timeout) == .completed
    }
}
