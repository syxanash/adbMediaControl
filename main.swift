import Foundation
import CoreGraphics
import AppKit

// Constants & Key Codes
let kF13: Int64 = 105
let kNumpadPlus: Int64  = 69
let kNumpadMinus: Int64 = 78
let kNumpadStar: Int64  = 67
let kNumpadEqual: Int64 = 81
let kNumpadSlash: Int64 = 75
let kNumpadDot: Int64 = 65
let kNumpad1: Int64 = 83
let kNumpad2: Int64 = 84
let kNumpad3: Int64 = 85
let kNumpad4: Int64 = 86
let kNumpad5: Int64 = 87
let kNumpad6: Int64 = 88
let kNumpad7: Int64 = 89
let kNumpad8: Int64 = 91
let kNumpad9: Int64 = 92

let kSlash: Int64 = 42 // acts as a left mouse click
let kTick: Int64 = 50  // acts as a right mouse click

let kArrowUp: Int64     = 126
let kArrowDown: Int64   = 125
let kArrowLeft: Int64   = 123
let kArrowRight: Int64  = 124

// Movement Physics
let baseSpeed: CGFloat = 2.0       // Starting speed (pixels per frame)
let acceleration: CGFloat = 0.4    // How fast it speeds up
let maxSpeed: CGFloat = 22.0       // Maximum velocity
var currentVelocity: CGFloat = 0.0

// macOS Media Key Constants
let NX_KEYTYPE_SOUND_UP: UInt32   = 0
let NX_KEYTYPE_SOUND_DOWN: UInt32 = 1
let NX_KEYTYPE_MUTE: UInt32       = 7
let NX_KEYTYPE_PLAY: UInt32       = 16
let NX_KEYTYPE_NEXT: UInt32       = 17
let NX_KEYTYPE_PREVIOUS: UInt32   = 18

enum KeyAction {
    case media(UInt32)
    case app([String])
}

// Config — lives at ~/Documents/adbMediaControl.json
let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents/adbMediaControl.json")

func createDefaultConfigIfNeeded() {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
    let template = """
    {
      "numpad1": "-a /Applications/Firefox.app https://simone.computer",
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
        kNumpadDot: .media(NX_KEYTYPE_MUTE),
    ]
    let numpadKeyCodes: [String: Int64] = [
        "numpad1": kNumpad1, "numpad2": kNumpad2, "numpad3": kNumpad3,
        "numpad4": kNumpad4, "numpad5": kNumpad5, "numpad6": kNumpad6,
        "numpad7": kNumpad7, "numpad8": kNumpad8, "numpad9": kNumpad9,
    ]
    for (key, args) in config {
        if let keyCode = numpadKeyCodes[key] {
            map[keyCode] = .app(args.components(separatedBy: " "))
        }
    }
    return map
}()

// State Management
var modifierIsDown = false
var activeArrows: Set<Int64> = []
var movementTimer: Timer?

// Core Functions

func moveMouse(dx: CGFloat, dy: CGFloat) {
    // Get current mouse location
    let dummyEvent = CGEvent(source: nil)
    guard let loc = dummyEvent?.location else { return }
    
    let newLoc = CGPoint(x: loc.x + dx, y: loc.y + dy)
    
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

func clickMouse(button: CGMouseButton, isDown: Bool) {
    let dummyEvent = CGEvent(source: nil)
    guard let loc = dummyEvent?.location else { return }
    
    let type: CGEventType = (button == .left) 
        ? (isDown ? .leftMouseDown : .leftMouseUp) 
        : (isDown ? .rightMouseDown : .rightMouseUp)
    
    let clickEvent = CGEvent(mouseEventSource: nil, mouseType: type, 
                             mouseCursorPosition: loc, mouseButton: button)
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

// Event Tap Callback

let callback: CGEventTapCallBack = { (proxy, type, event, refcon) in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // 1. Handle Modifier (F13)
    if keyCode == kF13 {
        if type == .keyDown { modifierIsDown = true } 
        else if type == .keyUp { 
            modifierIsDown = false 
            activeArrows.removeAll() // Safety clear
        }
        return nil 
    }

    if modifierIsDown {
        // 2. Handle Clicks
        if keyCode == kSlash {
            clickMouse(button: .left, isDown: (type == .keyDown))
            return nil
        }
        if keyCode == kTick {
            clickMouse(button: .right, isDown: (type == .keyDown))
            return nil
        }

        // 3. Handle Smooth Movement
        let isArrow = [kArrowUp, kArrowDown, kArrowLeft, kArrowRight].contains(keyCode)
        if isArrow {
            if type == .keyDown {
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

        // 4. Handle Media/Apps
        if type == .keyDown, let action = keyMap[keyCode] {
            switch action {
            case .media(let m): postMediaKey(key: m)
            case .app(let a): DispatchQueue.global().async { handleAppOpener(a) }
            }
            return nil
        }
        
        if type == .keyUp && keyMap.keys.contains(keyCode) { return nil }
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
    alert.informativeText = "adbMediaControl needs Accessibility permission to capture global key events.\n\nOpen System Settings → Privacy & Security → Accessibility and add adbMediaControl.app."
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
    
    let alert = NSAlert()
    alert.messageText = "ADB Media Control is running"
    alert.informativeText = "Running in the background.\n\nTo configure app shortcut keys, edit:\n~/Documents/adbMediaControl.json"
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Open Config File")
    alert.addButton(withTitle: "Close")

    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        NSWorkspace.shared.open(configURL)
    }
}

app.run()
