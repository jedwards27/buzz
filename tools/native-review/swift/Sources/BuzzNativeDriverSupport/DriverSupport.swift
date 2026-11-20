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

/// Which button to press for a first-run macOS privacy prompt, judged by its text,
/// or nil when the text is not one of the known prompts. Microphone and camera
/// access are declined (a review never needs them); the Local Network prompt is
/// allowed. Anything else is never answered.
public func privacyPromptButton(forAlertText text: String) -> String? {
    let lowered = text.lowercased()
    if lowered.contains("would like to access the microphone") || lowered.contains("would like to access the camera") {
        return "Don't Allow"
    }
    if lowered.contains("find devices on local networks") || lowered.contains("local network") {
        return "Allow"
    }
    return nil
}

/// A button title with typographic apostrophes folded to plain ones, so
/// "Don\u{2019}t Allow" (what macOS draws) matches "Don't Allow" (what people type).
public func normalizedButtonTitle(_ title: String) -> String {
    title.replacingOccurrences(of: "\u{2019}", with: "'")
}
