# KMC (Keyboard Mouse Control)

macOS menu bar utility that combines scroll reversal, mouse gesture-based Space switching, Caps Lock delay removal, and F1-F12 function key restoration in a single lightweight app.

> **Note:** 현재 UI는 한국어로 제공됩니다. This app is currently developed for Korean users.

<p align="center">
  <img src="screenshot.png" width="420" alt="KMC Settings">
</p>

## Why?

Jc가 MacBook Pro에서 Logitech G309 게이밍 마우스와 외장 키보드를 사용하던 중 겪은 불편함에서 시작된 프로젝트입니다.

- G309는 게이밍 마우스라 Logi Options+를 지원하지 않아 **스크롤 방향 반전**을 자체 설정할 수 없었고,
- 트랙패드의 **전체 화면 앱 쓸어넘기기**를 마우스로 대체할 방법이 없었으며,
- macOS의 **Caps Lock 한/영 전환 딜레이**가 빠른 타이핑을 방해했고,
- 외장 키보드에서 **F1~F12가 볼륨/밝기 등 미디어키로 동작**하여 엑셀 시트의 셀 편집(F2)이나 크롬 개발자 콘솔(F12) 같은 표준 기능키 단축키를 사용할 수 없었습니다.

이 네 가지 문제를 해결하기 위해 별도 프로그램 4개를 설치하는 대신, 하나의 가벼운 메뉴바 앱으로 직접 만들었습니다.

---

This project started when Jc encountered daily frustrations using a Logitech G309 gaming mouse with an external keyboard on a MacBook Pro.

- The G309 doesn't support Logi Options+, so there was no way to **reverse scroll direction** natively.
- There was no way to replicate the trackpad's **fullscreen app swipe gesture** with a mouse.
- The **Caps Lock delay for Korean/English input switching** on macOS was disrupting fast typing.
- External keyboard **F1-F12 keys acted as media keys** (volume, brightness) instead of standard function keys — making shortcuts like cell editing in Excel (F2) or opening Chrome DevTools (F12) impossible.

Instead of installing four separate utilities, Jc built a single lightweight menu bar app to solve all of them.

## Features

### 1. Scroll Reversal
- Independent mouse / trackpad reversal
- Vertical and horizontal axis control
- Adjustable scroll step multiplier
- Based on [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) (Apache 2.0)

### 2. Space Switching Gesture
- Hold a configurable mouse button + move left/right to switch between fullscreen apps / Spaces
- Uses synthetic DockSwipe events for native macOS animation
- Adjustable movement threshold (50-500px)
- Direction inversion option (natural / standard)
- Continuous swipe support (multiple switches in a single hold)
- Works with any HID button including vendor-specific buttons (e.g., Logitech G309 DPI button)

### 3. Caps Lock Delay Removal
- Eliminates the ~0.5s Caps Lock delay for Korean/English input switching
- Remaps Caps Lock → F18 via `hidutil` (bypasses all macOS Caps Lock special handling)
- Automatically sets F18 as the input source shortcut (no manual setup)
- Re-applied on app launch and wake from sleep

### 4. F1~F12 Standard Function Keys
- **External keyboard**: Intercepts media key events (NX_SYSDEFINED) via CGEventTap and converts them back to standard F1-F12 keyboard events
- **Internal keyboard**: Toggles macOS system preference (`com.apple.keyboard.fnState`) with one click
- Works in all apps including Chrome DevTools (F12)
- No Karabiner Elements required

### Menu Bar Indicator
- 4 colored dots below the mouse icon show which features are active
- Green = enabled, gray = disabled
- Dark mode compatible

## Requirements

- macOS 13.5+
- Accessibility permission (for event taps)
- Input Monitoring permission (for HID device access)

## Build

No Xcode required. Uses Swift Package Manager:

```bash
bash build-app.sh
```

The built app will be at `build/KMC_v{VERSION}.app`.

## Install

1. Move `KMC_v{VERSION}.app` to `/Applications`
2. Launch the app (appears in menu bar)
3. Grant Accessibility and Input Monitoring permissions when prompted
4. Enable desired features via the settings window

## How It Works

| Feature | Mechanism |
|---------|-----------|
| Scroll Reversal | Dual CGEventTap (active for modification, passive for touch detection) |
| Space Switching | IOHIDManager (button detection) + CGEventTap (movement tracking) + synthetic DockSwipe events |
| Caps Lock Fix | `hidutil` UserKeyMapping + `defaults write` symbolic hotkeys |
| F1~F12 Keys | CGEventTap (NX_SYSDEFINED interception) + async CGEvent posting with `hidSystemState` source |

## Acknowledgements

This project would not have been possible without the incredible work of the open source community.

### [Scroll Reverser](https://github.com/pilotmoon/Scroll-Reverser) by [@pilotmoon](https://github.com/pilotmoon) (Nick Moore)

A heartfelt and sincere thank you to Nick Moore for creating and open-sourcing Scroll Reverser. Your elegant implementation of dual CGEventTap architecture — with its precise mouse/trackpad source detection, touch-count tracking, and careful event field ordering — became the foundation upon which KMC was built. Without your meticulous work on scroll event handling, this project simply would not exist. Your code taught us how macOS processes scroll events at the deepest level, and that understanding inspired us to build additional features far beyond scroll reversal — including Space switching via synthetic DockSwipe events and media key interception for F-key restoration. We are deeply grateful for your generosity in sharing this work with the community under the Apache 2.0 license.

### [Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix) by [@noah-nuebling](https://github.com/noah-nuebling) (Noah Nuebling)

Sincere thanks to Noah Nuebling for the extraordinary reverse engineering work on macOS gesture internals. The synthetic DockSwipe event structure — with its undocumented CGEvent fields, phase sequences, and stuck-bug workarounds — was instrumental in implementing native Space switching with the same fluid animation as a real trackpad swipe. Your dedication to documenting these internals made it possible for others to build upon them.

### [Karabiner-Elements](https://github.com/pqrs-org/Karabiner-Elements) by [@tekezo](https://github.com/tekezo)

Thanks to tekezo for the Karabiner-Elements project, which served as the definitive reference for macOS HID device classification — particularly the internal keyboard detection approach using `kIOHIDBuiltInKey`, transport type, and product name matching that enabled KMC to correctly distinguish between built-in and external keyboards.

## License

Apache License 2.0 — see [LICENSE](LICENSE)

## Author

Jc
