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
/// no network, no keychain identity. That makes the flows deterministic, and
/// it is the reason these can assert on specific channel names at all.
@MainActor
final class NavigationFlows: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extraArguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"] + extraArguments
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

    /// Settings is a sheet over the channel list. Dismissing it must land back
    /// on the list, which is exactly the assertion that would have caught a
    /// dismiss that did nothing.
    func testSettingsOpensAndClosesBackToTheChannelList() {
        let app = launch()
        XCTAssertTrue(app.otherElements[A11y.channelList].waitForExistence(timeout: 20))

        app.buttons[A11y.settingsButton].tap()

        // Something only Settings shows, so this is evidence the screen
        // changed rather than that a tap was accepted.
        let settingsMarker = app.staticTexts["Notifications"]
        XCTAssertTrue(
            settingsMarker.waitForExistence(timeout: 10),
            "tapping the gear should actually present settings"
        )

        // A sheet dismisses by dragging down; using the gesture rather than a
        // button means this does not depend on which chrome the sheet happens
        // to carry.
        app.swipeDown(velocity: .fast)

        XCTAssertTrue(
            app.otherElements[A11y.channelList].waitForExistence(timeout: 10),
            "closing settings should land back on the channel list, not on a blank screen"
        )
        XCTAssertFalse(settingsMarker.exists, "settings should be gone, not merely covered")
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

        app.navigationBars.buttons.element(boundBy: 0).tap()
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
        XCTAssertTrue(send.isEnabled, "the send button should be live once there is something to send")
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
