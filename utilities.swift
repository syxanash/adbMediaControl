import Foundation
import CoreGraphics
import AppKit

func appDisplayName(from args: [String]) -> String {
    if let idx = args.firstIndex(of: "-a"), idx + 1 < args.count {
        let target = args[idx + 1]
        if target.hasSuffix(".app") {
            return URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
        }
        return target
    }
    return args.first ?? ""
}

func scrollMouse(dx: Int32, dy: Int32) {
    let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
    scrollEvent?.post(tap: .cghidEventTap)
}

func postMediaKey(key: UInt32) {
    let src = CGEventSource(stateID: .hidSystemState)
    func createEvent(isDown: Bool) -> NSEvent? {
        let flags = isDown ? 0xa00 : 0xb00
        let data1 = Int((Int32(key) << 16) | (isDown ? 0xa : 0xb) << 8)
        
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
    }
    if let evDown = createEvent(isDown: true)?.cgEvent { evDown.setSource(src); evDown.post(tap: .cghidEventTap) }
    if let evUp = createEvent(isDown: false)?.cgEvent { evUp.setSource(src); evUp.post(tap: .cghidEventTap) }
}

func handleAppOpener(_ processArgs: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = processArgs
    try? task.run()
}

func clampToDisplays(_ point: CGPoint, displays: [CGRect]) -> CGPoint {
    for display in displays {
        if display.contains(point) { return point }
    }
    var best = point
    var bestDist = CGFloat.infinity
    for display in displays {
        let cx = max(display.minX, min(display.maxX - 1, point.x))
        let cy = max(display.minY, min(display.maxY - 1, point.y))
        let dist = hypot(cx - point.x, cy - point.y)
        if dist < bestDist {
            bestDist = dist
            best = CGPoint(x: cx, y: cy)
        }
    }
    return best
}

func getDisplayBounds() -> [CGRect] {
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
    return displayIDs.map { CGDisplayBounds($0) }
}
