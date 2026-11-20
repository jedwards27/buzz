import CoreGraphics
import Testing
@testable import BuzzNativeDriverSupport

@Test func captureScheduleAdvancesAcrossBackpressure() {
    let start = ContinuousClock.now
    var schedule = CaptureSchedule(start: start, framesPerSecond: 15)

    let blockedTicks = (0..<4).map { _ in schedule.advance(isReadyForMoreMediaData: false) }

    #expect(blockedTicks.allSatisfy { !$0.shouldCapture })
    #expect(blockedTicks.map(\.presentationTime.value) == [0, 1, 2, 3])
    #expect(blockedTicks.map(\.deadline) == [
        start.advanced(by: .milliseconds(66)),
        start.advanced(by: .milliseconds(133)),
        start.advanced(by: .milliseconds(200)),
        start.advanced(by: .milliseconds(266)),
    ])
    #expect(schedule.frame == 4)
}

@Test func captureScheduleMarksReadyTickForCapture() {
    var schedule = CaptureSchedule()
    #expect(schedule.advance(isReadyForMoreMediaData: true).shouldCapture)
}

@Test func scrollEventUsesTargetFrameCenter() throws {
    let frame = CGRect(x: 40, y: 80, width: 120, height: 60)
    let event = try #require(makeScrollEvent(deltaY: 240, targetFrame: frame))

    #expect(event.location == CGPoint(x: 100, y: 110))
}


@Test func windowOnSecondaryDisplayMovesToCenterOfMainDisplay() throws {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let window = CGRect(x: -1016, y: 36, width: 1008, height: 726)

    let target = try #require(placementOnMainDisplay(window: window, mainDisplay: main))

    #expect(target.size == window.size)
    #expect(main.contains(target))
    #expect(target.midX == main.midX)
}

@Test func windowAlreadyOnMainDisplayIsLeftAlone() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    #expect(placementOnMainDisplay(window: CGRect(x: 100, y: 80, width: 1008, height: 726), mainDisplay: main) == nil)
}

@Test func windowUnderTheMenuBarOrPartlyOffscreenIsMoved() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    #expect(placementOnMainDisplay(window: CGRect(x: 100, y: 0, width: 800, height: 600), mainDisplay: main) != nil)
    #expect(placementOnMainDisplay(window: CGRect(x: 1000, y: 100, width: 800, height: 600), mainDisplay: main) != nil)
}

@Test func oversizedWindowIsShrunkToFitMainDisplay() throws {
    let main = CGRect(x: 0, y: 0, width: 1024, height: 768)
    let window = CGRect(x: -2000, y: 0, width: 1800, height: 1200)

    let target = try #require(placementOnMainDisplay(window: window, mainDisplay: main))

    #expect(main.contains(target))
    #expect(target.width <= main.width && target.height <= main.height)
}

@Test func microphoneAndCameraPromptsAreDeclined() {
    #expect(privacyPromptButton(forAlertText: "\"bloxlet\" would like to access the Microphone. Don't Allow Allow") == "Don't Allow")
    #expect(privacyPromptButton(forAlertText: "\"Terminal\" would like to access the Camera.") == "Don't Allow")
}

@Test func localNetworkPromptIsAllowed() {
    #expect(privacyPromptButton(forAlertText: "Allow \"bloxlet\" to find devices on local networks?") == "Allow")
}

@Test func unrelatedAlertsAreNeverAnswered() {
    #expect(privacyPromptButton(forAlertText: "Do you want to save changes? Allow") == nil)
    #expect(privacyPromptButton(forAlertText: "") == nil)
}

@Test func buttonTitlesCompareIgnoringTypographicApostrophes() {
    #expect(normalizedButtonTitle("Don\u{2019}t Allow") == normalizedButtonTitle("Don't Allow"))
    #expect(normalizedButtonTitle("Allow") != normalizedButtonTitle("Don't Allow"))
}
