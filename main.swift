import Foundation
import CoreGraphics
import AppKit

// Key codes
let kF13: Int64 = 105

let kNumpadPlus: Int64  = 69 // Volume Up
let kNumpadMinus: Int64 = 78 // Volume Down
let kNumpadStar: Int64  = 67 // Play
let kNumpadEqual: Int64 = 81 // Pause
let kNumpadSlash: Int64 = 75 // Next Song
let kNumpadDot: Int64 = 65   // dot sign
let kNumpad1: Int64 = 83     // 1 numpad
let kNumpad2: Int64 = 84     // 2 numpad
let kNumpad3: Int64 = 85     // 3 numpad

let kSlash: Int64 = 42 // acts as a left mouse click
let kTick: Int64 = 50  // acts as a right mouse click

let kArrowUp: Int64     = 126
let kArrowDown: Int64   = 125
let kArrowLeft: Int64   = 123
let kArrowRight: Int64  = 124

let mouseStep: CGFloat  = 20.0

// macOS Media Key Constants
let NX_KEYTYPE_SOUND_UP: UInt32   = 0
let NX_KEYTYPE_SOUND_DOWN: UInt32 = 1
let NX_KEYTYPE_MUTE: UInt32       = 7
let NX_KEYTYPE_PLAY: UInt32       = 16
let NX_KEYTYPE_NEXT: UInt32       = 17
let NX_KEYTYPE_PREVIOUS: UInt32   = 18

// Map keys to actions (media or app invocation)
enum KeyAction {
    case media(UInt32)
    case app([String])
}

let keyMap: [Int64: KeyAction] = [
    kNumpadPlus: .media(NX_KEYTYPE_SOUND_UP),
    kNumpadMinus: .media(NX_KEYTYPE_SOUND_DOWN),
    kNumpadStar: .media(NX_KEYTYPE_PLAY),
    kNumpadEqual: .media(NX_KEYTYPE_PREVIOUS),
    kNumpadSlash: .media(NX_KEYTYPE_NEXT),
    kNumpadDot: .media(NX_KEYTYPE_MUTE),
    kNumpad1: .app(["-a", "/Applications/Firefox.app", "-g", "http://simone.computer"]),
    kNumpad2: .app(["-a", "/Applications/Spotify.app"]),
    kNumpad3: .app(["-a", "/Applications/WhatsApp.app"])
]

var modifierIsDown = false

// CORE FUNCTIONS

func moveMouse(dx: CGFloat, dy: CGFloat) {
    guard let event = CGEvent(source: nil) else { return }
    var loc = event.location
    loc.x += dx
    loc.y += dy
    
    let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, 
                            mouseCursorPosition: loc, mouseButton: .left)
    moveEvent?.post(tap: .cghidEventTap)
}

func clickMouse(button: CGMouseButton, isDown: Bool) {
    guard let event = CGEvent(source: nil) else { return }
    let loc = event.location
    
    let type: CGEventType
    switch button {
    case .left:
        type = isDown ? .leftMouseDown : .leftMouseUp
    case .right:
        type = isDown ? .rightMouseDown : .rightMouseUp
    default:
        type = isDown ? .leftMouseDown : .leftMouseUp
    }
    
    let clickEvent = CGEvent(mouseEventSource: nil, mouseType: type, 
                             mouseCursorPosition: loc, mouseButton: button)
    clickEvent?.post(tap: .cghidEventTap)
}

func handleAppOpener(_ processArgs: [String]) {
    print("Spawning process...")

    let pathToScript = "/usr/bin/open"

    let task = Process()
    task.executableURL = URL(fileURLWithPath: pathToScript)
    task.arguments = processArgs
    try? task.run()
}

func postMediaKey(key: UInt32) {
    // Assign it to a variable 'src'
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

    // Convert NSEvent to CGEvent and set the source explicitly
    if let eventDown = createEvent(isDown: true)?.cgEvent {
        eventDown.setSource(src) // Link the event to the HID source
        eventDown.post(tap: .cghidEventTap)
    }
    
    if let eventUp = createEvent(isDown: false)?.cgEvent {
        eventUp.setSource(src) // Link the event to the HID source
        eventUp.post(tap: .cghidEventTap)
    }
}

// EVENT TAP CALLBACK

let callback: CGEventTapCallBack = { (proxy, type, event, refcon) in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

    // Handle Modifier (F13)
    if keyCode == kF13 {
        if type == .keyDown { modifierIsDown = true } 
        else if type == .keyUp { modifierIsDown = false }
        return nil 
    }

    if modifierIsDown {
        // 1. Handle Mouse Click actions
        if keyCode == kSlash {
            if type == .keyDown {
                clickMouse(button: .left, isDown: true)
            } else if type == .keyUp {
                clickMouse(button: .left, isDown: false)
            }
            return nil
        }

        if keyCode == kTick {
            if type == .keyDown {
                clickMouse(button: .right, isDown: true)
            } else if type == .keyUp {
                clickMouse(button: .right, isDown: false)
            }
            return nil
        }

        // 2. Handle Mouse Movement (Arrows)
        let isArrow = [kArrowUp, kArrowDown, kArrowLeft, kArrowRight].contains(keyCode)
        
        if type == .keyDown && isArrow {
            let dx: CGFloat = (keyCode == kArrowRight ? mouseStep : (keyCode == kArrowLeft ? -mouseStep : 0))
            let dy: CGFloat = (keyCode == kArrowDown ? mouseStep : (keyCode == kArrowUp ? -mouseStep : 0))
            moveMouse(dx: dx, dy: dy)
            return nil
        }

        // 3. Handle Media Keys / App Opener
        if type == .keyDown, let action = keyMap[keyCode] {
            switch action {
            case .media(let mediaKey):
                postMediaKey(key: mediaKey)
            case .app(let args):
                DispatchQueue.global().async {
                    handleAppOpener(args)
                }
            }
            return nil
        }
        
        // Swallow release of mapped keys
        if type == .keyUp && (isArrow || keyMap.keys.contains(keyCode)) {
            return nil
        }
    }

    return Unmanaged.passUnretained(event)
}

// SETUP & RUNLOOP

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
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: eventTap, enable: true)

let app = NSApplication.shared
DispatchQueue.main.async {
    let alert = NSAlert()
    alert.messageText = "ADB Media Control"
    alert.informativeText = "The driver is now running in the background..."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Ok")

    // This shows the alert window WITHOUT stopping the code execution
    alert.layout()
    alert.window.center()
    alert.window.makeKeyAndOrderFront(nil)

    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
       print("ADB Media Control Driver Active...")
    }
    
    // Optional: Bring it to the very front so the user sees it
    NSApp.activate(ignoringOtherApps: true)
}

app.run()