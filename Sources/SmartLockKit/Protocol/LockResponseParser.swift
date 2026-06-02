//
//  LockResponseParser.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation

/// Decoded telemetry from a lock status / acknowledgement frame.
public struct LockTelemetry: Equatable {
    public let replyStatus: ReplyStatus
    public let lockState: LockState
    public let alarmState: AlarmState
    public let batteryMillivolts: Int
    public let batteryPercentage: Int
    public let sealedCount: Int
    public let unsealedCount: Int
    public let timestamp: String
    public let rawFrameHex: String
}

/// Stateful parser that reassembles BLE notification fragments into complete
/// frames (delimited by `F3 3F` … `F4 4F`), then decrypts and decodes them.
///
/// BLE delivers data in ≤20-byte chunks, so a single response can span several
/// callbacks; the parser buffers until a full frame is available.
public final class LockResponseParser {

    private let aesKey: String
    private var buffer = Data()

    private let startMarker = Data([0xF3, 0x3F])
    private let endMarker   = Data([0xF4, 0x4F])

    public init(aesKey: String) {
        self.aesKey = aesKey
    }

    /// Feeds a freshly received chunk. Returns telemetry once a complete frame
    /// has been assembled and decoded, otherwise `nil` (more data needed).
    public func consume(_ chunk: Data) -> LockTelemetry? {
        buffer.append(chunk)

        guard let start = buffer.range(of: startMarker) else { return nil }
        if start.lowerBound > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<start.lowerBound)
        }

        guard let end = buffer.range(of: endMarker), end.upperBound <= buffer.endIndex else {
            return nil
        }

        let frame = buffer.subdata(in: buffer.startIndex..<end.upperBound)
        buffer.removeSubrange(buffer.startIndex..<end.upperBound)

        guard frame.count >= 31 else { return nil }
        return decode(frame)
    }

    public func reset() { buffer.removeAll() }

    // MARK: - Decoding

    private func decode(_ frame: Data) -> LockTelemetry? {
        let isEncrypted = frame[frame.startIndex + 2] == 0xFF && frame[frame.startIndex + 3] == 0xEE
        let rawHex = frame.hexString

        if isEncrypted {
            let encrypted = frame.subdata(in: (frame.startIndex + 8)..<(frame.startIndex + 28))
            guard let decrypted = try? AES128.decrypt(encrypted, key: aesKey), decrypted.count >= 7 else {
                return nil
            }
            // decrypted = CRC(2) ‖ serial(6) ‖ nonce(4) ‖ content
            let content = decrypted.subdata(in: 12..<decrypted.count)
            return decodeContent(content, rawHex: rawHex)
        } else {
            // Unencrypted layout is offset by the 8-byte header.
            let content = frame.subdata(in: (frame.startIndex + 8)..<frame.endIndex)
            return decodeContent(content, rawHex: rawHex)
        }
    }

    private func decodeContent(_ content: Data, rawHex: String) -> LockTelemetry? {
        let bytes = [UInt8](content)
        guard bytes.count >= 7 else { return nil }

        let reply = ReplyStatus(rawValue: bytes[0]) ?? .otherError
        let lock = LockState(rawValue: bytes[1]) ?? .unknown
        let alarm = AlarmState(rawValue: bytes[2]) ?? .unknown
        let millivolts = (Int(bytes[3]) << 8) | Int(bytes[4])

        var sealed = 0, unsealed = 0
        if bytes.count >= 13 {
            sealed = Self.beInt(Array(bytes[5...8]))
            unsealed = Self.beInt(Array(bytes[9...12]))
        }

        var timestamp = ""
        if bytes.count >= 20 {
            timestamp = Self.formatBCDTime(Array(bytes[13...19]))
        }

        return LockTelemetry(
            replyStatus: reply,
            lockState: lock,
            alarmState: alarm,
            batteryMillivolts: millivolts,
            batteryPercentage: Self.batteryPercentage(millivolts: millivolts),
            sealedCount: sealed,
            unsealedCount: unsealed,
            timestamp: timestamp,
            rawFrameHex: rawHex
        )
    }

    // MARK: - Helpers

    /// Big-endian 4-byte integer.
    static func beInt(_ bytes: [UInt8]) -> Int {
        var result = 0
        for (i, byte) in bytes.enumerated() {
            result |= Int(byte) << (8 * (3 - i))
        }
        return result
    }

    /// Maps a Li-ion discharge curve (mV) to an approximate 0–100% level.
    static func batteryPercentage(millivolts: Int) -> Int {
        let volts = Double(millivolts) / 1000.0
        if volts <= 3.0 { return 0 }
        if volts >= 4.2 { return 100 }

        let (base, maxV, minV, span): (Int, Double, Double, Int) = {
            switch volts {
            case 4.06..<4.2:  return (90, 4.2, 4.06, 10)
            case 3.98..<4.06: return (80, 4.06, 3.98, 10)
            case 3.92..<3.98: return (70, 3.98, 3.92, 10)
            case 3.87..<3.92: return (60, 3.92, 3.87, 10)
            case 3.82..<3.87: return (50, 3.87, 3.82, 10)
            case 3.79..<3.82: return (40, 3.82, 3.79, 10)
            case 3.77..<3.79: return (30, 3.79, 3.77, 10)
            case 3.74..<3.77: return (20, 3.77, 3.74, 10)
            case 3.68..<3.74: return (10, 3.74, 3.68, 10)
            case 3.45..<3.68: return (5, 3.68, 3.45, 5)
            default:          return (0, 3.45, 3.0, 5)
            }
        }()
        return Int(Double(base) + Double(span) * (volts - minV) / (maxV - minV))
    }

    /// Decodes 6 packed-BCD bytes (`yyMMddHHmmss`) into `"YY-MM-DD HH:MM:SS"`.
    static func formatBCDTime(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 6 else { return "" }
        func bcd(_ b: UInt8) -> String { String(format: "%d%d", b >> 4, b & 0x0F) }
        return "\(bcd(bytes[0]))-\(bcd(bytes[1]))-\(bcd(bytes[2])) \(bcd(bytes[3])):\(bcd(bytes[4])):\(bcd(bytes[5]))"
    }
}
