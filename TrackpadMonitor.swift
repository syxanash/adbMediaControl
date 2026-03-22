import Foundation

// MARK: - MultitouchSupport Private Framework Types

fileprivate struct MTPoint {
    var x: Float = 0
    var y: Float = 0
}

fileprivate struct MTVector {
    var position: MTPoint = MTPoint()
    var velocity: MTPoint = MTPoint()
}

// Layout must match the C struct from MultitouchSupport.framework.
// If position values look wrong at runtime, the padding between `frame`
// and `timestamp` is the most likely culprit — Swift should align Double
// to 8 bytes automatically (matching the C ABI), but verify with a quick
// print of touch.normalized.position when a finger is in a known corner.
fileprivate struct MTTouch {
    var frame: Int32       = 0   // offset  0
    var timestamp: Double  = 0   // offset  8 (4-byte pad inserted by alignment)
    var identifier: Int32  = 0   // offset 16
    var state: Int32       = 0   // offset 20  — 1..6 = on surface, 7 = lifted
    var unknown1: Int32    = 0   // offset 24
    var unknown2: Int32    = 0   // offset 28
    var normalized: MTVector = MTVector()  // offset 32  (position.x, .y, velocity.x, .y)
    var size: Float        = 0   // offset 48
    var zero1: Int32       = 0
    var angle: Float       = 0
    var majorAxis: Float   = 0
    var minorAxis: Float   = 0
    var mm: MTVector       = MTVector()
    var zero2: (Int32, Int32) = (0, 0)
    var densityF: Float    = 0
}

// Use RawPointer for the touches parameter — Swift won't let a Swift struct
// appear directly in a @convention(c) signature. We cast it inside handleFrame.
private typealias MTContactCallbackFn  = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, Int32, Double, Int32) -> Void
private typealias MTDeviceCreateListFn = @convention(c) () -> CFArray
private typealias MTRegisterCallbackFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallbackFn) -> Void
private typealias MTDeviceStartFn      = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

// MARK: - File-scope C callback (required by C callback ABI)

private weak var _sharedMonitor: TrackpadMonitor?

private let _mtCallback: MTContactCallbackFn = { _, rawTouches, count, timestamp, _ in
    _sharedMonitor?.handleFrame(rawTouches: rawTouches, count: Int(count), timestamp: timestamp)
}

// MARK: - TrackpadMonitor

class TrackpadMonitor {

    /// Bottom-left corner zone: finger must be within this fraction of the trackpad edge.
    var cornerThreshold: Float = 0.25

    /// Maximum touch duration (seconds) that counts as a tap, not a hold.
    var maxTapSeconds: Double = 0.35

    var enabled: Bool = true

    /// Called on the main queue when a corner tap is detected.
    var onCornerTap: (() -> Void)?

    // identifier → time the finger first entered the corner
    private var cornerFingers: [Int32: Double] = [:]

    init() {
        _sharedMonitor = self
        startDevices()
    }

    // MARK: Setup

    private func startDevices() {
        guard
            let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MultitouchSupport.framework"),
            bundle.load()
        else {
            print("[ADBridge] MultitouchSupport framework not available")
            return
        }

        let handle = dlopen(nil, RTLD_LAZY)
        guard
            let pList     = dlsym(handle, "MTDeviceCreateList"),
            let pRegister = dlsym(handle, "MTRegisterContactFrameCallback"),
            let pStart    = dlsym(handle, "MTDeviceStart")
        else {
            print("[ADBridge] MultitouchSupport symbols missing")
            return
        }

        let createList = unsafeBitCast(pList,     to: MTDeviceCreateListFn.self)
        let register   = unsafeBitCast(pRegister, to: MTRegisterCallbackFn.self)
        let startDev   = unsafeBitCast(pStart,    to: MTDeviceStartFn.self)

        let devices = createList() as [AnyObject]
        for device in devices {
            let ptr = Unmanaged.passUnretained(device).toOpaque()
            register(ptr, _mtCallback)
            startDev(ptr, 0)
        }
    }

    // MARK: Frame handler (called from main RunLoop)

    fileprivate func handleFrame(rawTouches: UnsafeMutableRawPointer, count: Int, timestamp: Double) {
        guard enabled else { cornerFingers.removeAll(); return }
        let touches = rawTouches.assumingMemoryBound(to: MTTouch.self)
        var seen = Set<Int32>()

        for i in 0..<count {
            let t = touches[i]
            seen.insert(t.identifier)

            // (0,0) = bottom-left corner of the trackpad surface
            let inCorner = t.normalized.position.x < cornerThreshold
                        && t.normalized.position.y < cornerThreshold

            if t.state == 7 {
                // Finger lifted — fire tap if it started in the corner and was short enough
                if let start = cornerFingers.removeValue(forKey: t.identifier),
                   timestamp - start < maxTapSeconds {
                    DispatchQueue.main.async { [weak self] in self?.onCornerTap?() }
                }
            } else if cornerFingers[t.identifier] == nil, inCorner {
                // New finger appearing in the corner
                cornerFingers[t.identifier] = timestamp
            } else if !inCorner {
                // Finger drifted out of the corner — cancel
                cornerFingers.removeValue(forKey: t.identifier)
            }
        }

        // Identifiers absent from this frame have silently lifted — clean up
        for id in Array(cornerFingers.keys) where !seen.contains(id) {
            cornerFingers.removeValue(forKey: id)
        }
    }
}
