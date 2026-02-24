import Foundation
import CoreGraphics
import AppKit

let configFile: String = "Documents/adbridgeConfig.json"

let modifierKey: Int64 = kF13

// Mouse Controls
let leftClick: Int64 = kNumpad0       // acts as a left mouse click
let rightClick: Int64 = kNumpadEnter  // acts as a right mouse click
let middleClick: Int64 = kNumpadDot   // acts as a middle mouse click                                                                                

let kArrowUp: Int64     = kNumpad5
let kArrowDown: Int64   = kNumpad2
let kArrowLeft: Int64   = kNumpad1
let kArrowRight: Int64  = kNumpad3

let kScrollUp: Int64 = kNumpad7
let kScrollDown: Int64 = kNumpad4
let kScrollRight: Int64 = kNumpad9
let kScrollLeft: Int64 = kNumpad8

// Movement Physics
let baseSpeed: CGFloat = 2.0       // Starting speed (pixels per frame)
let acceleration: CGFloat = 0.4    // How fast it speeds up
let maxSpeed: CGFloat = 22.0       // Maximum velocity
var currentVelocity: CGFloat = 0.0

// Scroll Physics
let scrollBaseSpeed: CGFloat = 3.0
let scrollAcceleration: CGFloat = 0.8
let scrollMaxSpeed: CGFloat = 30.0
var scrollVelocity: CGFloat = 0.0

enum KeyAction {
    case media(UInt32)
    case app([String])
}

let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(configFile)

func createDefaultConfigIfNeeded() {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
    let template = """
    {
      "num1": "-a /Applications/Firefox.app https://simone.computer",
    }
    """
    try? template.write(to: configURL, atomically: true, encoding: .utf8)
}

func loadConfig() -> [String: String] {
    createDefaultConfigIfNeeded()
    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode([String: String].self, from: data) else {
        return [:]
    }
    return config
}

let config = loadConfig()

let keyMap: [Int64: KeyAction] = {
    var map: [Int64: KeyAction] = [
        kNumpadPlus: .media(NX_KEYTYPE_SOUND_UP),
        kNumpadMinus: .media(NX_KEYTYPE_SOUND_DOWN),
        kNumpadStar: .media(NX_KEYTYPE_PLAY),
        kNumpadEqual: .media(NX_KEYTYPE_PREVIOUS),
        kNumpadSlash: .media(NX_KEYTYPE_NEXT),
        kNumpad6: .app(["-a", "Mission Control"]),
    ]
    let numpadKeyCodes: [String: Int64] = [
        "num1": numsRows1, "num2": numsRows2, "num3": numsRows3,
        "num4": numsRows4, "num5": numsRows5, "num6": numsRows6,
        "num7": numsRows7, "num8": numsRows8, "num9": numsRows9,
        "num0": numsRows0,
    ]
    for (key, args) in config {
        if let keyCode = numpadKeyCodes[key] {
            map[keyCode] = .app(args.components(separatedBy: " "))
        }
    }
    return map
}()

// State Management
var toggleActive = false
var modifierIsHeld = false
var modifierPressTime: TimeInterval = 0
let modifierHoldThreshold: TimeInterval = 0.4   // seconds; >= this → hold mode, < this → toggle mode
var mouseHasMovedWhileToggled = false
let numberRowKeys: Set<Int64> = [numsRows0, numsRows1, numsRows2, numsRows3, numsRows4, numsRows5, numsRows6, numsRows7, numsRows8, numsRows9]
let arrowKeys: Set<Int64>     = [kArrowUp, kArrowDown, kArrowLeft, kArrowRight]
let scrollKeys: Set<Int64>    = [kScrollUp, kScrollDown, kScrollLeft, kScrollRight]
var activeArrows: Set<Int64> = []
var movementTimer: Timer?

var activeScrolls: Set<Int64> = []
var scrollTimer: Timer?

var statusItem: NSStatusItem?

var lastClickTime: TimeInterval = 0
var clickCount: Int64 = 1
var leftClickIsDown = false
var rightClickIsDown = false
var middleClickIsDown = false

var cachedDisplayBounds: [CGRect] = getDisplayBounds()
let cachedIconFilled: NSImage? = { let img = NSImage(contentsOfFile: Bundle.main.resourcePath! + "/triangle-fill.png"); img?.isTemplate = true; return img }()
let cachedIconEmpty: NSImage?  = { let img = NSImage(contentsOfFile: Bundle.main.resourcePath! + "/triangle.png");      img?.isTemplate = true; return img }()

// Core Functions

func setStatusIcon(filled: Bool) {
    guard let button = statusItem?.button else { return }
    if let image = filled ? cachedIconFilled : cachedIconEmpty {
        button.image = image
    } else {
        button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ADBridge")
        button.image?.isTemplate = true
    }
}

func scrollMouse(dx: Int32, dy: Int32) {
    let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
    scrollEvent?.post(tap: .cghidEventTap)
}

func getDisplayBounds() -> [CGRect] {
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &displayCount)
    var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
    CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
    return displayIDs.map { CGDisplayBounds($0) }
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

func moveMouse(dx: CGFloat, dy: CGFloat) {
    let dummyEvent = CGEvent(source: nil)
    guard let loc = dummyEvent?.location else { return }

    let rawLoc = CGPoint(x: loc.x + dx, y: loc.y + dy)
    let newLoc = clampToDisplays(rawLoc, displays: cachedDisplayBounds)

    let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: newLoc, mouseButton: .left)
    moveEvent?.post(tap: .cghidEventTap)
}

func updateMouseLoop() {
    guard !activeArrows.isEmpty else {
        currentVelocity = 0
        return
    }

    // Smoothly increase velocity
    if currentVelocity < maxSpeed {
        currentVelocity += acceleration
    }

    var dx: CGFloat = 0
    var dy: CGFloat = 0

    let step = baseSpeed + currentVelocity

    if activeArrows.contains(kArrowRight) { dx += step }
    if activeArrows.contains(kArrowLeft)  { dx -= step }
    if activeArrows.contains(kArrowDown)  { dy += step }
    if activeArrows.contains(kArrowUp)    { dy -= step }

    moveMouse(dx: dx, dy: dy)
}

func updateScrollLoop() {
    guard !activeScrolls.isEmpty else {
        scrollVelocity = 0
        return
    }

    if scrollVelocity < scrollMaxSpeed {
        scrollVelocity += scrollAcceleration
    }

    let step = Int32(scrollBaseSpeed + scrollVelocity)
    var scrollDeltaY: Int32 = 0
    var scrollDeltaX: Int32 = 0

    if activeScrolls.contains(kScrollUp)    { scrollDeltaY += step }
    if activeScrolls.contains(kScrollDown)  { scrollDeltaY -= step }
    if activeScrolls.contains(kScrollRight) { scrollDeltaX -= step }
    if activeScrolls.contains(kScrollLeft)  { scrollDeltaX += step }

    scrollMouse(dx: scrollDeltaX, dy: scrollDeltaY)
}

func clickMouse(button: CGMouseButton, isDown: Bool) {
    let dummyEvent = CGEvent(source: nil)
    guard let loc = dummyEvent?.location else { return }
    
    let type: CGEventType
    switch button {
    case .left:   type = isDown ? .leftMouseDown  : .leftMouseUp
    case .right:  type = isDown ? .rightMouseDown : .rightMouseUp
    default:      type = isDown ? .otherMouseDown : .otherMouseUp  // center/middle
    }
    
    if isDown {
        let currentTime = Date().timeIntervalSince1970
        // If the click happened within 0.5 seconds of the last one, it's a double/triple click
        if (currentTime - lastClickTime) < 0.5 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClickTime = currentTime
    }

    let clickEvent = CGEvent(mouseEventSource: nil, mouseType: type, 
                             mouseCursorPosition: loc, mouseButton: button)

    clickEvent?.setIntegerValueField(.mouseEventClickState, value: clickCount)
    
    clickEvent?.post(tap: .cghidEventTap)
}

func handleAppOpener(_ processArgs: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = processArgs
    try? task.run()
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

func deactivateToggle() {
    toggleActive = false
    modifierIsHeld = false
    mouseHasMovedWhileToggled = false
    DispatchQueue.main.async { setStatusIcon(filled: false) }

    activeArrows.removeAll()
    movementTimer?.invalidate()
    movementTimer = nil
    currentVelocity = 0

    activeScrolls.removeAll()
    scrollTimer?.invalidate()
    scrollTimer = nil
    scrollVelocity = 0

    if leftClickIsDown {
        leftClickIsDown = false
        clickMouse(button: .left, isDown: false)
    }
    if rightClickIsDown {
        rightClickIsDown = false
        clickMouse(button: .right, isDown: false)
    }
    if middleClickIsDown {
        middleClickIsDown = false
        clickMouse(button: .center, isDown: false)
    }
}

// Event Tap Callback

let callback: CGEventTapCallBack = { (proxy, type, event, refcon) in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // 1. Handle Modifier - quick tap toggles, hold deactivates on release
    if keyCode == modifierKey {
        if type == .keyDown && !modifierIsHeld {
            modifierIsHeld = true
            if toggleActive {
                deactivateToggle()
            } else {
                toggleActive = true
                mouseHasMovedWhileToggled = false
                modifierPressTime = Date().timeIntervalSince1970
                DispatchQueue.main.async { setStatusIcon(filled: true) }
            }
        } else if type == .keyUp {
            modifierIsHeld = false
            // Only deactivate if the key was held long enough (hold mode)
            if toggleActive && (Date().timeIntervalSince1970 - modifierPressTime) >= modifierHoldThreshold {
                deactivateToggle()
            }
        }
        return nil
    }

    if toggleActive {
        // 2. Handle Clicks
        if keyCode == leftClick {
            leftClickIsDown = (type == .keyDown)
            clickMouse(button: .left, isDown: (type == .keyDown))
            return nil
        }
        if keyCode == rightClick {
            rightClickIsDown = (type == .keyDown)
            clickMouse(button: .right, isDown: (type == .keyDown))
            return nil
        }
        if keyCode == middleClick {
            middleClickIsDown = (type == .keyDown)
            clickMouse(button: .center, isDown: (type == .keyDown))
            return nil
        }

        // 3. Handle Smooth Movement
        let isArrow = arrowKeys.contains(keyCode)
        if isArrow {
            if type == .keyDown {
                mouseHasMovedWhileToggled = true
                activeArrows.insert(keyCode)
                if movementTimer == nil {
                    // 120Hz update for smooth movement
                    movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { _ in
                        updateMouseLoop()
                    }
                }
            } else if type == .keyUp {
                activeArrows.remove(keyCode)
                if activeArrows.isEmpty {
                    movementTimer?.invalidate()
                    movementTimer = nil
                    currentVelocity = 0
                }
            }
            return nil
        }

        // 4. Handle Scrolling
        let isScroll = scrollKeys.contains(keyCode)
        if isScroll {
            if type == .keyDown {
                activeScrolls.insert(keyCode)
                if scrollTimer == nil {
                    scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
                        updateScrollLoop()
                    }
                }
            } else if type == .keyUp {
                activeScrolls.remove(keyCode)
                if activeScrolls.isEmpty {
                    scrollTimer?.invalidate()
                    scrollTimer = nil
                    scrollVelocity = 0
                }
            }
            return nil
        }

        // 5. Handle Media/Apps
        if let action = keyMap[keyCode] {
            // Pass through number row keys if the mouse was used (let them type normally)
            if mouseHasMovedWhileToggled && numberRowKeys.contains(keyCode) {
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                switch action {
                case .media(let m): postMediaKey(key: m)
                case .app(let a): DispatchQueue.global().async { handleAppOpener(a) }
                }
            }
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}

// Setup & Run
let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

guard let eventTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(mask),
    callback: callback,
    userInfo: nil
) else {
    let app = NSApplication.shared
    app.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Accessibility Permission Required"
    alert.informativeText = "ADBridge needs Accessibility permission to capture global key events.\n\nOpen System Settings → Privacy & Security → Accessibility and add ADBridge.app"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Quit")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    exit(1)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

let app = NSApplication.shared
DispatchQueue.main.async {
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate()

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    setStatusIcon(filled: false)

    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in
        cachedDisplayBounds = getDisplayBounds()
    }

    let menu = NSMenu()
    let quitItem = NSMenuItem(title: "Quit ADBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    quitItem.target = NSApp
    menu.addItem(quitItem)
    statusItem?.menu = menu

    let alert = NSAlert()
    alert.messageText = "ADBridge is running!"
    alert.informativeText = "To configure app shortcut keys, edit:\n~\(configFile)"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open Config File")
    alert.addButton(withTitle: "Close")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        NSWorkspace.shared.open(configURL)
    }
}

app.run()
