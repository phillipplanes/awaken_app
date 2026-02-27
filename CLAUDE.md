# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Awaken is a pillow-based smart alarm clock that wakes the user with haptics and sound conducted through the pillow. It has two components:
- **iOS App** (Swift/SwiftUI) — BLE client for setting alarm time
- **ESP32 Device** (C++/Arduino) — Adafruit ESP32-S3 TFT Feather with DRV2605L haptic driver + P2305D ERM motor, Adafruit STEMMA Audio Amp (I2S), and built-in 240x135 ST7789 TFT display

The user sets an alarm via the iOS app, which sends the time over BLE to the ESP32 device. When the alarm triggers, the device activates haptics and sound through the pillow.

## Build Commands

### iOS App
```bash
# Open in Xcode
open awaken/awaken.xcodeproj

# Build from CLI
xcodebuild -scheme awaken -configuration Debug build

# Run tests
xcodebuild -scheme awaken test -destination 'platform=iOS Simulator,name=iPhone 16'
```

### ESP32 Firmware (PlatformIO)
```bash
# Build
pio run -d awaken/firmware

# Upload to device
pio run -d awaken/firmware --target upload

# Serial monitor
pio device monitor --baud 115200
```

## Architecture

### iOS App (`awaken/awaken/`)
MVVM pattern with two main files:
- **BluetoothViewModel.swift** — `ObservableObject` implementing `CBCentralManagerDelegate` and `CBPeripheralDelegate`. Manages BLE scanning, connection, service/characteristic discovery, and writes alarm time to the ESP32.
- **ContentView.swift** — SwiftUI view with three states: scanning (peripheral list), connected (time picker + set alarm button), and status display. Drives all UI from `BluetoothViewModel`'s `@Published` properties.

### ESP32 Firmware (`awaken/firmware/src/main.cpp`)
Single-file Arduino sketch handling:
- Wi-Fi connection and NTP time sync (UTC-5)
- BLE server with callbacks for connection and characteristic writes
- ST7789 TFT display (built-in SPI, 240x135, backlight on GPIO45) showing current time and alarm status
- I2C on STEMMA QT (SDA=3, SCL=4) for DRV2605L haptic driver
- I2S audio to STEMMA Audio Amp (BCLK=5, LRC=6, DIN=9)
- Alarm matching logic in the main loop (1-second interval)

### BLE Protocol
Both sides must use matching UUIDs:
- Service: `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
- Characteristic: `beb5483e-36e1-4688-b7f5-ea07361b26a8`
- Data format: UTF-8 string `"HH:mm"` (24-hour format)

## Key Dependencies

**iOS:** SwiftUI, CoreBluetooth, Combine, Foundation

**ESP32 (via PlatformIO):** NTPClient, Adafruit ST7789 + GFX (TFT driver), Adafruit DRV2605, Adafruit BusIO, built-in WiFi/BLE/I2S libraries
