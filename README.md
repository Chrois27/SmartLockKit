# SmartLockKit

[![CI](https://github.com/Chrois27/SmartLockKit/actions/workflows/ci.yml/badge.svg)](https://github.com/Chrois27/SmartLockKit/actions/workflows/ci.yml)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2013+%20%7C%20macOS%2011+-blue.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Chrois27/SmartLockKit?sort=semver)](https://github.com/Chrois27/SmartLockKit/releases)

A clean, dependency-free Swift package for driving a **BLE smart padlock** that
speaks an encrypted command protocol over the Nordic UART Service (NUS) profile.

It covers the full path end-to-end:

> **discover → connect → AES-encrypted command → reassemble & decrypt → typed telemetry**

Built with `CoreBluetooth`, `CommonCrypto` and zero third-party dependencies.
Runs on iOS and macOS, and the protocol layer is fully unit-tested on CI without
any hardware attached.

```
┌─────────────────────────────────────────────────────────────────┐
│                        SmartLockManager                           │  facade
│        (credentials, high-level unlock()/lock()/status())         │
└───────────────┬───────────────────────────────┬──────────────────┘
                │ outbound                       │ inbound
        ┌───────▼────────┐              ┌────────▼─────────┐
        │ LockCommand    │              │ LockResponse     │
        │ Builder        │              │ Parser           │
        │ frame + AES    │              │ reassemble + AES │
        └───────┬────────┘              └────────▲─────────┘
                │  Data                          │ Data chunks
        ┌───────▼────────────────────────────────┴─────────┐
        │              BLEPeripheralClient                  │  transport
        │   CoreBluetooth central · NUS · chunked writes    │
        └───────────────────────────────────────────────────┘
```

## Highlights

- **Binary protocol engineering** — builds a 43-byte command frame with header/tail
  markers, a CRC-16/CCITT-FALSE integrity check, an incrementing serial and a random
  nonce, then AES-128 encrypts the payload.
- **ECB done responsibly** — the firmware mandates AES-128/ECB; the frame layer adds a
  per-message CRC + serial + nonce so identical commands never repeat on the wire.
- **Robust BLE reassembly** — BLE delivers ≤20-byte fragments, so the parser buffers
  between `F3 3F … F4 4F` markers until a full frame is available.
- **Testable by design** — timestamp and nonce are dependency-injected, making frame
  generation deterministic under test.
- **Reusable transport** — `BLEPeripheralClient` is configurable (device name, service /
  characteristic UUIDs, timeouts, MTU) and defaults to standard Nordic UART UUIDs.

## Installation

Swift Package Manager — add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Chrois27/SmartLockKit.git", from: "1.0.0")
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and paste the repository URL.

## Usage

```swift
import SmartLockKit

let manager = SmartLockManager(
    credentials: .init(password: "********", aesKey: "****************"),
    deviceNamePrefix: "MyLock"
)
manager.delegate = self
manager.connect()

// later…
manager.unlock()
manager.refreshStatus()

// SmartLockManagerDelegate
func smartLock(_ manager: SmartLockManager, didReceive telemetry: LockTelemetry) {
    print(telemetry.lockState, telemetry.batteryPercentage, telemetry.timestamp)
}
```

> Credentials (8-char password, 16-char AES key) are **injected by the caller** and are
> never stored in the library.

## Command frame

```
┌──────┬──────┬───────┬────────┬────────────────────────┬──────────┬──────┐
│ F1 1F│ FF EE│ 24 01 │ 00 20  │   AES-128/ECB ( 32 B )  │ checksum │ F2 2F│
│ head │ enc. │  cmd  │ len=32 │ CRC‖serial‖nonce‖content │  (1 B)   │ tail │
└──────┴──────┴───────┴────────┴────────────────────────┴──────────┴──────┘
```

## Build & test

```bash
swift build
swift test      # 14 tests — crypto, CRC, frame structure, parser
```

## Modules

| File | Responsibility |
|------|----------------|
| `Crypto/AES128.swift` | AES-128/ECB wrapper over CommonCrypto |
| `Crypto/CRC16.swift` | CRC-16/CCITT-FALSE (`Data` extension) |
| `Protocol/LockModels.swift` | Commands, reply/lock/alarm enums |
| `Protocol/LockCommandBuilder.swift` | Outbound frame construction |
| `Protocol/LockResponseParser.swift` | Inbound reassembly + decode → `LockTelemetry` |
| `Transport/BLEPeripheralClient.swift` | CoreBluetooth central (NUS profile) |
| `SmartLockManager.swift` | High-level facade |

## License

MIT © Chris Choi
