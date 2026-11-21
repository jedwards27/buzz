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

// The real prompt, as the VM's accessibility tree shows it.
private func systemPrompt(
    text: String = "\u{201C}LauncherHost\u{201D} would like to access the Microphone.",
    buttons: [String] = ["Help", "Don\u{2019}t Allow", "Allow"],
    bundleID: String? = "com.apple.UserNotificationCenter",
    executable: String? = "/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter",
    role: String? = "AXWindow",
    subrole: String? = "AXSystemDialog"
) -> PromptWindow {
    PromptWindow(ownerBundleID: bundleID, ownerExecutablePath: executable, role: role,
                 subrole: subrole, texts: [text, ""], buttons: buttons)
}

@Test func promptTextNamesTheKindAndTheApp() {
    #expect(parsePrivacyPrompt(texts: ["\u{201C}LauncherHost\u{201D} would like to access the Microphone."])
        == PrivacyPrompt(kind: .microphone, appName: "LauncherHost"))
    #expect(parsePrivacyPrompt(texts: ["\"Terminal\" would like to access the Camera."])
        == PrivacyPrompt(kind: .camera, appName: "Terminal"))
    #expect(parsePrivacyPrompt(texts: ["Allow \u{201C}Python\u{201D} to find devices on local networks?", "This will allow the app to discover"])
        == PrivacyPrompt(kind: .localNetwork, appName: "Python"))
    #expect(parsePrivacyPrompt(texts: ["Do you want to save changes? Allow"]) == nil)
    #expect(parsePrivacyPrompt(texts: ["would like to access the Microphone."]) == nil)
}

@Test func theRealMicrophonePromptIsDeclinedWhenItNamesAProcessOfTheReview() {
    #expect(decidePrivacyPrompt(systemPrompt(), expectedApps: ["LauncherHost", "Buzz Native Review"]) == .press("Don't Allow"))
}

@Test func theRealLocalNetworkPromptIsAllowedWhenItNamesAProcessOfTheReview() {
    let prompt = systemPrompt(text: "Allow \u{201C}Python\u{201D} to find devices on local networks?",
                              buttons: ["Don\u{2019}t Allow", "Allow"])
    #expect(decidePrivacyPrompt(prompt, expectedApps: ["python"]) == .press("Allow"))
}

@Test func aPromptNamingAnotherAppIsNeverAnswered() {
    guard case .skip(let reason) = decidePrivacyPrompt(systemPrompt(text: "\u{201C}Zoom\u{201D} would like to access the Microphone."),
                                                       expectedApps: ["LauncherHost", "Buzz Native Review"]) else {
        Issue.record("answered a prompt for another app"); return
    }
    #expect(reason.contains("Zoom"))
}

@Test func aWindowNotOwnedBySystemPromptAgentIsNeverAnswered() {
    // Same words, same buttons, wrong owner: a web page or app drawing a lookalike.
    for impostor in [
        systemPrompt(bundleID: "com.apple.Safari"),
        systemPrompt(bundleID: nil),
        systemPrompt(executable: "/Users/someone/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter"),
        systemPrompt(executable: nil),
        systemPrompt(executable: "/System/Library/CoreServices/../../../tmp/evil"),
    ] {
        guard case .skip = decidePrivacyPrompt(impostor, expectedApps: ["LauncherHost"]) else {
            Issue.record("answered a window the system prompt agent does not own: \(impostor)"); continue
        }
    }
}

@Test func aWindowThatIsNotASystemAlertIsNeverAnswered() {
    for other in [systemPrompt(role: "AXSheet"), systemPrompt(subrole: "AXStandardWindow"), systemPrompt(subrole: nil), systemPrompt(role: nil)] {
        guard case .skip = decidePrivacyPrompt(other, expectedApps: ["LauncherHost"]) else {
            Issue.record("answered a window that is not a system dialog: \(other)"); continue
        }
    }
}

@Test func aPromptWithoutTheExpectedButtonOrWithDuplicatesIsNotAnswered() {
    guard case .skip = decidePrivacyPrompt(systemPrompt(buttons: ["Help", "Allow"]), expectedApps: ["LauncherHost"]) else {
        Issue.record("pressed a missing button"); return
    }
    guard case .skip = decidePrivacyPrompt(systemPrompt(buttons: ["Don\u{2019}t Allow", "Don't Allow"]), expectedApps: ["LauncherHost"]) else {
        Issue.record("pressed an ambiguous button"); return
    }
}

@Test func anEmptyExpectedSetNeverMatches() {
    guard case .skip = decidePrivacyPrompt(systemPrompt(), expectedApps: []) else {
        Issue.record("answered with nothing to identify the app by"); return
    }
}

@Test func theReportedWindowIsTheOneThatMoves() {
    let reported = CGRect(x: -1016, y: 36, width: 1008, height: 726)
    let others = [CGRect(x: 40, y: 40, width: 300, height: 200), CGRect(x: -1015, y: 36, width: 1008, height: 726)]
    #expect(matchingWindowIndex(frames: others, reported: reported) == 1)
    #expect(matchingWindowIndex(frames: [CGRect(x: 40, y: 40, width: 300, height: 200)], reported: reported) == nil)
    #expect(matchingWindowIndex(frames: [], reported: reported) == nil)
}

@Test func aMovedWindowIsVerifiedOnlyWhenItIsWhollyOnTheMainDisplay() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    #expect(windowIsOnMainDisplay(CGRect(x: 100, y: 80, width: 1008, height: 726), mainDisplay: main))
    #expect(!windowIsOnMainDisplay(CGRect(x: -1016, y: 36, width: 1008, height: 726), mainDisplay: main))
}

@Test func buttonTitlesCompareIgnoringTypographicApostrophes() {
    #expect(normalizedButtonTitle("Don\u{2019}t Allow") == normalizedButtonTitle("Don't Allow"))
    #expect(normalizedButtonTitle("Allow") != normalizedButtonTitle("Don't Allow"))
}
