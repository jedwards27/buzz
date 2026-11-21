import CoreGraphics
import CoreMedia
import Foundation

public struct CaptureTick {
    public let shouldCapture: Bool
    public let presentationTime: CMTime
    public let deadline: ContinuousClock.Instant
}

public struct CaptureSchedule {
    private let start: ContinuousClock.Instant
    private let framesPerSecond: Int64
    public private(set) var frame: Int64 = 0

    public init(start: ContinuousClock.Instant = .now, framesPerSecond: Int64 = 15) {
        self.start = start
        self.framesPerSecond = framesPerSecond
    }

    public mutating func advance(isReadyForMoreMediaData: Bool) -> CaptureTick {
        let tick = CaptureTick(
            shouldCapture: isReadyForMoreMediaData,
            presentationTime: CMTime(value: frame, timescale: Int32(framesPerSecond)),
            deadline: start.advanced(by: .milliseconds(Int((frame + 1) * 1000 / framesPerSecond)))
        )
        frame += 1
        return tick
    }
}

public func makeScrollEvent(deltaY: Int32, targetFrame: CGRect) -> CGEvent? {
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .pixel,
        wheelCount: 1,
        wheel1: deltaY,
        wheel2: 0,
        wheel3: 0
    ) else { return nil }
    event.location = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    return event
}

/// Where to put a window so it sits wholly on the main display, centered, below
/// the menu bar. Returns nil when it is already there. A window larger than the
/// usable area is shrunk to fit.
public func placementOnMainDisplay(window: CGRect, mainDisplay: CGRect, menuBarHeight: CGFloat = 30) -> CGRect? {
    let usable = CGRect(x: mainDisplay.minX, y: mainDisplay.minY + menuBarHeight,
                        width: mainDisplay.width, height: mainDisplay.height - menuBarHeight)
    if usable.contains(window) { return nil }
    let size = CGSize(width: min(window.width, usable.width), height: min(window.height, usable.height))
    return CGRect(x: usable.midX - size.width / 2, y: usable.midY - size.height / 2,
                  width: size.width, height: size.height)
}

public enum PrivacyPromptKind: Equatable, Sendable { case microphone, camera, localNetwork }

public struct PrivacyPrompt: Equatable, Sendable {
    public var kind: PrivacyPromptKind
    public var appName: String
    public init(kind: PrivacyPromptKind, appName: String) {
        self.kind = kind
        self.appName = appName
    }
}

/// What the driver can see of a candidate prompt window: who owns it, what kind
/// of accessibility window it is, and the text and buttons inside it.
public struct PromptWindow: Equatable, Sendable {
    public var ownerBundleID: String?
    public var ownerExecutablePath: String?
    public var role: String?
    public var subrole: String?
    public var texts: [String]
    public var buttons: [String]
    public init(ownerBundleID: String?, ownerExecutablePath: String?, role: String?,
                subrole: String?, texts: [String], buttons: [String]) {
        self.ownerBundleID = ownerBundleID
        self.ownerExecutablePath = ownerExecutablePath
        self.role = role
        self.subrole = subrole
        self.texts = texts
        self.buttons = buttons
    }
}

public enum PromptDecision: Equatable, Sendable {
    case press(String)
    case skip(String)
}

/// The process macOS draws its privacy (TCC) prompts with. Observed on a macOS 26
/// VM: the alert is an `AXWindow` with subrole `AXSystemDialog`, owned by this
/// bundle, running from the sealed system volume.
public let systemPromptBundleID = "com.apple.UserNotificationCenter"
public let systemPromptExecutablePrefix = "/System/Library/CoreServices/UserNotificationCenter.app/"

/// Read the kind of prompt and the app it names (the first quoted name) from the
/// alert's text. nil when the text is not a known privacy prompt.
public func parsePrivacyPrompt(texts: [String]) -> PrivacyPrompt? {
    let text = texts.joined(separator: " ")
    let lowered = text.lowercased()
    let kind: PrivacyPromptKind
    if lowered.contains("would like to access the microphone") {
        kind = .microphone
    } else if lowered.contains("would like to access the camera") {
        kind = .camera
    } else if lowered.contains("to find devices on local networks") {
        kind = .localNetwork
    } else {
        return nil
    }
    let quotes: Set<Character> = ["\u{201C}", "\u{201D}", "\""]
    let characters = Array(text)
    guard let open = characters.firstIndex(where: { quotes.contains($0) }),
          let close = characters[(open + 1)...].firstIndex(where: { quotes.contains($0) }) else { return nil }
    let name = String(characters[(open + 1)..<close])
    guard !name.isEmpty else { return nil }
    return PrivacyPrompt(kind: kind, appName: name)
}

/// Decide whether to answer a window, and with which button. The driver only
/// answers a window that is positively the system's own privacy alert for a
/// process of this review: owned by the system prompt agent and run from the
/// system volume, a system-dialog alert, naming one of `expectedApps`, and
/// holding exactly one button with the title to press. Anything else is skipped
/// with the reason, so nothing a page or another app draws is ever clicked.
/// Microphone and camera are declined (a review never needs them); Local Network
/// is allowed.
public func decidePrivacyPrompt(_ window: PromptWindow, expectedApps: [String]) -> PromptDecision {
    guard window.ownerBundleID == systemPromptBundleID else {
        return .skip("window is not owned by the system prompt agent (owner: \(window.ownerBundleID ?? "unknown"))")
    }
    guard let executable = window.ownerExecutablePath,
          URL(fileURLWithPath: executable).standardizedFileURL.path.hasPrefix(systemPromptExecutablePrefix) else {
        return .skip("window owner does not run from the system prompt agent's path")
    }
    guard window.role == "AXWindow", window.subrole == "AXSystemDialog" else {
        return .skip("window is not a system dialog (role: \(window.role ?? "none"), subrole: \(window.subrole ?? "none"))")
    }
    guard let prompt = parsePrivacyPrompt(texts: window.texts) else {
        return .skip("window text is not a known privacy prompt")
    }
    let names = Set(expectedApps.map { $0.lowercased() })
    guard names.contains(prompt.appName.lowercased()) else {
        return .skip("prompt names \"\(prompt.appName)\", which is not a process of this review")
    }
    let wanted = prompt.kind == .localNetwork ? "Allow" : "Don't Allow"
    let matching = window.buttons.filter { normalizedButtonTitle($0) == normalizedButtonTitle(wanted) }
    guard matching.count == 1 else {
        return .skip("expected exactly one \"\(wanted)\" button, found \(matching.count)")
    }
    return .press(wanted)
}

/// The index of the accessibility window whose frame is the window the harness
/// reports (within `tolerance` points), or nil. Never falls back to another window.
public func matchingWindowIndex(frames: [CGRect], reported: CGRect, tolerance: CGFloat = 2) -> Int? {
    frames.firstIndex { frame in
        abs(frame.minX - reported.minX) <= tolerance && abs(frame.minY - reported.minY) <= tolerance
            && abs(frame.width - reported.width) <= tolerance && abs(frame.height - reported.height) <= tolerance
    }
}

/// True when the window sits wholly on the main display below the menu bar.
public func windowIsOnMainDisplay(_ window: CGRect, mainDisplay: CGRect) -> Bool {
    placementOnMainDisplay(window: window, mainDisplay: mainDisplay) == nil
}

/// A button title with typographic apostrophes folded to plain ones, so
/// "Don\u{2019}t Allow" (what macOS draws) matches "Don't Allow" (what people type).
public func normalizedButtonTitle(_ title: String) -> String {
    title.replacingOccurrences(of: "\u{2019}", with: "'")
}
