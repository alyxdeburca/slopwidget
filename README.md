<img src="assets/icon.svg" width="64" height="64" alt="">

# slopWidget

Cross-platform iOS and WidgetKit project created in [T3 Code](https://t3.codes), configured for:
- **[isim](https://github.com/kolabs-dev/isim)**: iOS simulator and toolchain on Linux (no Mac needed).
- **[xtool](https://github.com/xtool-org/xtool)**: Cross-platform iOS build, signing, and physical device deployment (Linux / Windows / macOS).
- **Xcode**: Native macOS iOS Simulator and device development.

---

## Architecture & Project Structure

- **[Package.swift](Package.swift)**: Swift Package Manager manifest defining both the `slopWidget` app target, `slopWidgetExtension` WidgetKit target, and `slopWidgetTests` test suite (iOS 17+, macOS 14+).
- **[xtool.yml](xtool.yml)**: Configuration file for `xtool`, binding the application bundle identifier (`com.example.slopWidget`) and the widget extension product.
- **[slopWidgetExtension-Info.plist](slopWidgetExtension-Info.plist)**: Declares `com.apple.widgetkit-extension` for WidgetKit discovery.
- **[slopWidget/](slopWidget/)**: Application source code:
  - [`slopWidgetApp.swift`](slopWidget/slopWidgetApp.swift): App scene lifecycle.
  - [`ContentView.swift`](slopWidget/ContentView.swift): App interactive dashboard and live widget preview.
  - [`AuthManager.swift`](slopWidget/AuthManager.swift): Centralized `@MainActor` credential storage and state manager for Antigravity, Codex, and OpenCode Go.
  - [`LoginSheetView.swift`](slopWidget/LoginSheetView.swift): Interactive account management modal sheet.
  - `Assets.xcassets`: App icons and accent colors.
- **[slopWidgetExtension/](slopWidgetExtension/)**: Widget extension source code:
  - [`slopWidgetExtension.swift`](slopWidgetExtension/slopWidgetExtension.swift): WidgetKit `WidgetBundle`, timeline provider, and custom views for small, medium, and lock screen accessory widgets.
- **[Tests/slopWidgetTests/](Tests/slopWidgetTests/)**: Unit test suite:
  - [`AuthManagerTests.swift`](Tests/slopWidgetTests/AuthManagerTests.swift): Tests credential initialization, login, logout, whitespace sanitization, and JSON serialization.
  - [`ProviderUsageTests.swift`](Tests/slopWidgetTests/ProviderUsageTests.swift): Tests quota math, percentage rounding, and overflow clamping.
- **[.github/workflows/test.yml](.github/workflows/test.yml)**: CI test automation workflow compatible with GitHub Actions and local `act` runs.

---

## Testing

### Run Tests Locally (isim)
Run the full iOS XCTest suite on Linux with zero container overhead:
```bash
isim test -package-path . -scheme slopWidget
```

### Run Tests via `act` / GitHub Actions
Execute the CI workflow locally from the command line using `act`:
```bash
# Verify available jobs in act
act -l

# Run the test workflow locally
act
```
*(Note: requires your user to be added to the Docker group: `sudo usermod -aG docker $USER && newgrp docker`).*

---

## 1. Running in the iOS Simulator on Linux (isim)

`isim` is installed at `~/.local/bin/isim`. It allows building and running iOS apps in a simulated iPhone window directly on your Linux desktop.

### Build the App for Simulator
```bash
isim build -project slopWidget.xcodeproj -scheme slopWidget
```
Builds the app into `build/slopWidget.app`.

### Launch the Interactive Simulator
```bash
# Boot the simulator to the home screen
isim boot

# Or run slopWidget directly in the simulator
isim run build/slopWidget.app
```

### Render Previews to PNG
```bash
isim preview build/slopWidget.app 0 -o preview.png
```

---

## 2. Deploying to a Physical iPhone (xtool)

`xtool` is installed at `~/.local/bin/xtool` with Swift 6.4.1 toolchain and Darwin SDK (`iPhoneOS27.1.sdk`).

### Authenticate
```bash
xtool auth login
```

### Build & Deploy
With your iPhone connected via USB (trusted):
```bash
xtool dev
```
`xtool` builds the app and widget extension, signs them with your Apple ID certificate, and installs them onto your connected device.

---

## 3. Development with Xcode (macOS)

Open `slopWidget.xcworkspace` in Xcode 16 or later:
1. Select an iOS Simulator or physical device.
2. Select the `slopWidget` scheme and click **Run**.
3. Under **Signing & Capabilities**, select your development team and adjust bundle IDs if needed.
