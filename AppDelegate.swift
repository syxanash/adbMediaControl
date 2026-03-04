import Foundation
import CoreGraphics
import AppKit

// MARK: File-scope Constants

private let configFile = "Documents/adbridgeConfig.json"
private let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(configFile)

private let modifierKey: Int64 = kF13

private let leftClick: Int64   = kNumpad0
private let rightClick: Int64  = kNumpadEnter
private let middleClick: Int64 = kNumpadDot

private let kArrowUp: Int64    = kNumpad5
private let kArrowDown: Int64  = kNumpad2
private let kArrowLeft: Int64  = kNumpad1
private let kArrowRight: Int64 = kNumpad3

private let kScrollUp: Int64    = kNumpad7
private let kScrollDown: Int64  = kNumpad4
private let kScrollRight: Int64 = kNumpad9
private let kScrollLeft: Int64  = kNumpad8

private let baseSpeed: CGFloat            = 2.0
private let accelerationDefault: CGFloat  = 0.3
private let maxSpeedDefault: CGFloat      = 15.0
private let accelerationBoost: CGFloat    = 1.0
private let maxSpeedBoost: CGFloat        = 30.0

private let scrollBaseSpeed: CGFloat          = 3.0
private let scrollAccelerationDefault: CGFloat = 0.5
private let scrollAccelerationBoost: CGFloat   = 2.0
private let scrollMaxSpeedDefault: CGFloat     = 20.0
private let scrollMaxSpeedBoost: CGFloat       = 150.0

private let modifierHoldThreshold: TimeInterval = 0.2

private let numberRowKeys: Set<Int64> = [numsRows0, numsRows1, numsRows2, numsRows3, numsRows4,
                                          numsRows5, numsRows6, numsRows7, numsRows8, numsRows9]
private let arrowKeys: Set<Int64>  = [kArrowUp, kArrowDown, kArrowLeft, kArrowRight]
private let scrollKeys: Set<Int64> = [kScrollUp, kScrollDown, kScrollLeft, kScrollRight]

// MARK: Key Action Enum

enum KeyAction {
    case media(UInt32)
    case app([String])
}

// MARK: Config Helpers

private func createDefaultConfigIfNeeded() {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
    let template = """
    {
      "num1": "-a /Applications/Firefox.app https://simone.computer",
      "appShortcut": true,
      "mouseKeypad": true,
      "mediaKeys": true
    }
    """
    try? template.write(to: configURL, atomically: true, encoding: .utf8)
}

private func loadConfig() -> [String: Any] {
    createDefaultConfigIfNeeded()
    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return config
}

// MARK: Event Tap Bridge (file-scope; required by C callback ABI)

private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
    return delegate.handleEvent(proxy: proxy, type: type, event: event)
}

// MARK: AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: State
    var appShortcutEnabled = true
    var mouseFromKeypadEnabled = true
    var mediaKeysFromNumpadEnabled = true

    var toggleActive = false
    var modifierIsHeld = false
    var modifierPressedWhileActive = false
    var modifierUsedForAction = false
    var boostActive = false
    var modifierPressTime: TimeInterval = 0

    var acceleration: CGFloat  = accelerationDefault
    var maxSpeed: CGFloat      = maxSpeedDefault
    var currentVelocity: CGFloat = 0.0

    var scrollVelocity: CGFloat    = 0.0
    var scrollMaxSpeed: CGFloat    = scrollMaxSpeedDefault
    var scrollAcceleration: CGFloat = scrollAccelerationDefault

    var activeArrows: Set<Int64> = []
    var movementTimer: Timer?

    var activeScrolls: Set<Int64> = []
    var scrollTimer: Timer?

    var statusItem: NSStatusItem?
    var toastWindow: NSWindow?

    var cachedDisplayBounds: [CGRect] = []
    var cachedIconFilled: NSImage?
    var cachedIconEmpty: NSImage?

    var lastClickTime: TimeInterval = 0
    var clickCount: Int64 = 1
    var leftClickIsDown = false
    var rightClickIsDown = false
    var middleClickIsDown = false

    let config: [String: Any]
    let keyMap: [Int64: KeyAction]

    // MARK: Init

    override init() {
        config = loadConfig()

        appShortcutEnabled      = config["appShortcut"] as? Bool ?? true
        mouseFromKeypadEnabled  = config["mouseKeypad"] as? Bool ?? true
        mediaKeysFromNumpadEnabled = config["mediaKeys"] as? Bool ?? true

        var map: [Int64: KeyAction] = [
            kNumpadPlus:  .media(NX_KEYTYPE_SOUND_UP),
            kNumpadMinus: .media(NX_KEYTYPE_SOUND_DOWN),
            kNumpadStar:  .media(NX_KEYTYPE_PLAY),
            kNumpadEqual: .media(NX_KEYTYPE_PREVIOUS),
            kNumpadSlash: .media(NX_KEYTYPE_NEXT),
            kNumpad6:     .app(["-a", "Mission Control"]),
        ]
        let numpadKeyCodes: [String: Int64] = [
            "num1": numsRows1, "num2": numsRows2, "num3": numsRows3,
            "num4": numsRows4, "num5": numsRows5, "num6": numsRows6,
            "num7": numsRows7, "num8": numsRows8, "num9": numsRows9,
            "num0": numsRows0,
        ]
        for (key, value) in config {
            if let args = value as? String, let keyCode = numpadKeyCodes[key] {
                map[keyCode] = .app(args.components(separatedBy: " "))
            }
        }
        keyMap = map

        super.init()
    }

    // MARK: Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupCaches()
        setupEventTap()
        setupStatusBar()
        setupMenu()
        setupNotifications()
        showStartupAlert()
    }

    private func setupCaches() {
        cachedDisplayBounds = getDisplayBounds()
        let resourcePath = Bundle.main.resourcePath ?? ""
        // let resourcePath = "app-assets"
        cachedIconFilled = {
            let img = NSImage(contentsOfFile: resourcePath + "/triangle-fill.png")
            img?.isTemplate = true
            return img
        }()
        cachedIconEmpty = {
            let img = NSImage(contentsOfFile: resourcePath + "/triangle.png")
            img?.isTemplate = true
            return img
        }()
    }

    private func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            NSApp.activate(ignoringOtherApps: true)

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
    }

    private func setupStatusBar() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setStatusIcon(filled: false)
    }

    private func setupMenu() {
        let menu = NSMenu()
        
        let appShortcutItem = NSMenuItem(
            title: appShortcutEnabled ? "Disable App Shortcut" : "Enable App Shortcut",
            action: #selector(toggleAppShortcut(_:)),
            keyEquivalent: "",
        )
        appShortcutItem.state = appShortcutEnabled ? .on : .off
        appShortcutItem.target = self

        let mouseKeypadItem = NSMenuItem(
            title: appShortcutEnabled ? "Disable Keypad Mouse" : "Enable Keypad Mouse",
            action: #selector(toggleMouseFromKeypad(_:)),
            keyEquivalent: "",
        )
        mouseKeypadItem.state = mouseFromKeypadEnabled ? .on : .off
        mouseKeypadItem.target = self

        let mediaKeysKeypadItem = NSMenuItem(
            title: mediaKeysFromNumpadEnabled ? "Disable Keypad Media Keys" : "Enable Keypad Media Keys",
            action: #selector(toggleMediaKeysFromKeypad(_:)),
            keyEquivalent: "",
        )
        mediaKeysKeypadItem.state = mediaKeysFromNumpadEnabled ? .on : .off
        mediaKeysKeypadItem.target = self

        let quitItem = NSMenuItem(title: "Quit ADBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        menu.addItem(appShortcutItem)
        menu.addItem(mouseKeypadItem)
        menu.addItem(mediaKeysKeypadItem)
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cachedDisplayBounds = getDisplayBounds()
        }
    }

    private func showStartupAlert() {
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

    // MARK: Config Persistence

    private func saveConfig() {
        var updated = config
        updated["appShortcut"] = appShortcutEnabled
        updated["mouseKeypad"] = mouseFromKeypadEnabled
        updated["mediaKeys"]   = mediaKeysFromNumpadEnabled
        guard let data = try? JSONSerialization.data(withJSONObject: updated, options: .prettyPrinted) else { return }
        try? data.write(to: configURL)
    }

    // MARK: Menu Actions

    @objc func toggleAppShortcut(_ sender: NSMenuItem) {
        appShortcutEnabled.toggle()
        sender.title = appShortcutEnabled ? "Disable App Shortcut" : "Enable App Shortcut"
        sender.state = appShortcutEnabled ? .on : .off
        saveConfig()
    }

    @objc func toggleMouseFromKeypad(_ sender: NSMenuItem) {
        mouseFromKeypadEnabled.toggle()
        sender.title = mouseFromKeypadEnabled ? "Disable Keypad Mouse" : "Enable Keypad Mouse"
        sender.state = mouseFromKeypadEnabled ? .on : .off
        saveConfig()
    }

    @objc func toggleMediaKeysFromKeypad(_ sender: NSMenuItem) {
        mediaKeysFromNumpadEnabled.toggle()
        sender.title = mediaKeysFromNumpadEnabled ? "Disable Keypad Media Keys" : "Enable Keypad Media Keys"
        sender.state = mediaKeysFromNumpadEnabled ? .on : .off
        saveConfig()
    }

    // MARK: Status Icon

    func setStatusIcon(filled: Bool) {
        guard let button = statusItem?.button else { return }
        if let image = filled ? cachedIconFilled : cachedIconEmpty {
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ADBridge")
            button.image?.isTemplate = true
        }
    }

    // MARK: Toast

    func showAppToast(name: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.toastWindow?.orderOut(nil)

            let padding: CGFloat = 16
            let fontSize: CGFloat = 20
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
            let textSize = (name as NSString).size(withAttributes: [.font: font])
            let width = textSize.width + padding * 2
            let height = textSize.height + padding - 14

            guard let screen = NSScreen.main else { return }
            let sf = screen.frame
            let win = NSWindow(
                contentRect: NSRect(x: sf.midX - width / 2, y: sf.minY + 50, width: width, height: height),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            win.backgroundColor = .clear
            win.isOpaque = false
            win.level = .floating
            win.ignoresMouseEvents = true

            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            container.layer?.cornerRadius = 8

            let label = NSTextField(labelWithString: name)
            label.frame = container.bounds
            label.alignment = .center
            label.textColor = .white
            label.font = font
            container.addSubview(label)

            win.contentView = container
            win.orderFront(nil)
            self.toastWindow = win

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak win] in
                guard let self, let win, self.toastWindow === win else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    win.animator().alphaValue = 0
                }, completionHandler: { [weak self, weak win] in
                    win?.orderOut(nil)
                    if let win, self?.toastWindow === win { self?.toastWindow = nil }
                })
            }
        }
    }

    // MARK: Deactivate Toggle

    func deactivateToggle() {
        toggleActive = false
        modifierIsHeld = false
        DispatchQueue.main.async { [weak self] in self?.setStatusIcon(filled: false) }

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

    // MARK: Mouse Movement

    func updateMouseLoop() {
        guard !activeArrows.isEmpty else {
            currentVelocity = 0
            return
        }

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

    func moveMouse(dx: CGFloat, dy: CGFloat) {
        let dummyEvent = CGEvent(source: nil)
        guard let loc = dummyEvent?.location else { return }

        let rawLoc = CGPoint(x: loc.x + dx, y: loc.y + dy)
        let newLoc = clampToDisplays(rawLoc, displays: cachedDisplayBounds)

        let moveType: CGEventType
        if leftClickIsDown {
            moveType = .leftMouseDragged
        } else if rightClickIsDown {
            moveType = .rightMouseDragged
        } else if middleClickIsDown {
            moveType = .otherMouseDragged
        } else {
            moveType = .mouseMoved
        }

        let moveEvent = CGEvent(mouseEventSource: nil, mouseType: moveType,
                                mouseCursorPosition: newLoc, mouseButton: .left)
        moveEvent?.post(tap: .cghidEventTap)
    }

    func clickMouse(button: CGMouseButton, isDown: Bool) {
        let dummyEvent = CGEvent(source: nil)
        guard let loc = dummyEvent?.location else { return }

        let type: CGEventType
        switch button {
        case .left:   type = isDown ? .leftMouseDown  : .leftMouseUp
        case .right:  type = isDown ? .rightMouseDown : .rightMouseUp
        default:      type = isDown ? .otherMouseDown : .otherMouseUp
        }

        if isDown {
            let currentTime = Date().timeIntervalSince1970
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

    // MARK: Event Handling

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let shiftIsHeld = event.flags.contains(.maskShift)

        if shiftIsHeld != boostActive {
            boostActive = shiftIsHeld
            currentVelocity = 0
            scrollVelocity = 0
        }

        if shiftIsHeld {
            scrollAcceleration = scrollAccelerationBoost
            scrollMaxSpeed = scrollMaxSpeedBoost
            acceleration = accelerationBoost
            maxSpeed = maxSpeedBoost
        } else {
            scrollAcceleration = scrollAccelerationDefault
            scrollMaxSpeed = scrollMaxSpeedDefault
            acceleration = accelerationDefault
            maxSpeed = maxSpeedDefault
        }

        // 1. Handle Modifier - quick tap toggles, hold deactivates on release
        if keyCode == modifierKey {
            if type == .keyDown && !modifierIsHeld {
                modifierIsHeld = true
                modifierPressTime = Date().timeIntervalSince1970
                if toggleActive {
                    modifierPressedWhileActive = true
                } else {
                    toggleActive = true
                    DispatchQueue.main.async { [weak self] in self?.setStatusIcon(filled: true) }
                }
            } else if type == .keyUp {
                modifierIsHeld = false
                if toggleActive {
                    if modifierPressedWhileActive {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            guard let self else { return }
                            if !self.modifierUsedForAction { self.deactivateToggle() }
                            self.modifierPressedWhileActive = false
                            self.modifierUsedForAction = false
                        }
                    } else if (Date().timeIntervalSince1970 - modifierPressTime) >= modifierHoldThreshold {
                        deactivateToggle()
                    }
                } else {
                    modifierPressedWhileActive = false
                    modifierUsedForAction = false
                }
            }
            return nil
        }

        if toggleActive {
            if mouseFromKeypadEnabled {
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
                if arrowKeys.contains(keyCode) {
                    if type == .keyDown {
                        activeArrows.insert(keyCode)
                        if movementTimer == nil {
                            movementTimer = Timer.scheduledTimer(withTimeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
                                self?.updateMouseLoop()
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
                if scrollKeys.contains(keyCode) {
                    if type == .keyDown {
                        activeScrolls.insert(keyCode)
                        if scrollTimer == nil {
                            scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
                                self?.updateScrollLoop()
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
            }

            // 5. Handle Media/Apps
            if let action = keyMap[keyCode] {
                if !modifierIsHeld && numberRowKeys.contains(keyCode) {
                    return Unmanaged.passUnretained(event)
                }
                if type == .keyDown {
                    switch action {
                    case .media(let m):
                        guard mediaKeysFromNumpadEnabled else { return Unmanaged.passUnretained(event) }
                        postMediaKey(key: m)
                    case .app(let a):
                        if modifierPressedWhileActive { modifierUsedForAction = true }
                        if keyCode == kNumpad6 {
                            if mouseFromKeypadEnabled { DispatchQueue.global().async { handleAppOpener(a) } } else { return Unmanaged.passUnretained(event) }
                        } else if appShortcutEnabled {
                            showAppToast(name: appDisplayName(from: a))
                            DispatchQueue.global().async { handleAppOpener(a) }
                        }
                    }
                }
                return nil
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
