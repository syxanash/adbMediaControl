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
    kNumpad1: .app(["-a", "/Applications/Firefox.app", "-g", "http://simone.computer"])
]

var modifierIsDown = false

// CORE FUNCTIONS

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

    if keyCode == kF13 {
        if type == .keyDown { modifierIsDown = true } 
        else if type == .keyUp { modifierIsDown = false }
        return nil 
    }

    if modifierIsDown {
        if type == .keyDown {
            if let action = keyMap[keyCode] {
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
        }
        
        // Block the release of these keys too
        let mediaKeys: [Int64] = [kNumpadPlus, kNumpadMinus, kNumpadStar, kNumpadEqual, kNumpadSlash]
        if type == .keyUp && mediaKeys.contains(keyCode) {
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
    print("ADB Media Control + Mouse Driver Active...")
}

app.run()