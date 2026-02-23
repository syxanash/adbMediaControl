# ADBridge

<img src='repo-assets/icon.png' alt='app icon' style='height: 150px'><br>

## Requirements

You need to be able to configure the key mapping of your ADB to USB converter. The Apple IIGS Keyboard [converter](https://www.bigmessowires.com/usb-wombat/) I used was configured to map the Power Key <kbd>◁&nbsp;&nbsp;&nbsp;</kbd> to <kbd>F13</kbd>. This will be needed to use the function key as a modifier to use the extra shortcuts provided by ADBridge. You can easily change the line `let modifierKey: Int64 = kF13` in the `main.swift` and point your preferred function key from `constants.swift`.

## Shortcuts

ADBridge will provide the following keyboard shortcuts by default:

![keyboard mapping diagram](repo-assets/keyboard-map.png)

## Setup and Installation

### 1. Clone the repository

```
git clone https://github.com/syxanash/ADBridge
cd ADBridge
```

### 2. Build the .app

Execute this bash script which will allow you to generate a signed `ADBridge.app` on the fly.

```
./build.sh
```

### 3. Permissions

Copy the newly generated `ADBridge.app` to `Applications/` folder.
Open System Settings → Privacy & Security → Accessibility and add ADBridge.app

## Debug

If you just want to try the app in the terminal before building the final `.app` file just run:

```
swiftc *.swift -o adbridge && ./adbridge
```

## Configuration

By default ADBridge creates a config file `~/Documents/adbridgeConfig.json`. The format looks like this:

```
{
  "num1": "-a /System/Applications/Utilities/Terminal.app",
  "num2": "-a /Applications/Firefox.app,
  "num4": "-a /Applications/Spotify.app",
  "num5": "-a /Applications/WhatsApp.app",
  "num6": "-a /Applications/Telegram.app"
}
```

Each "num" on the number row can be configured to open an Application (similar to a macOS Dock).

You can quit ADBridge by clicking on the triangle icon on the menu bar:

![menu bar](repo-assets/menubar.png)