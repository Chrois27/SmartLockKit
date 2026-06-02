//
//  LockCommandBuilder.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation

/// Builds an encrypted command frame for the lock.
///
/// Frame layout (43 bytes):
/// ```
/// ┌──────┬──────┬───────┬────────┬───────────────────┬──────────┬──────┐
/// │ F1 1F│ FF EE│ 24 01 │ 00 20  │ AES-128/ECB(32 B)  │ checksum │ F2 2F│
/// │ head │ enc. │  cmd  │ length │  encrypted payload │  (1 B)   │ tail │
/// └──────┴──────┴───────┴────────┴───────────────────┴──────────┴──────┘
/// ```
/// The encrypted payload is `CRC16(content) ‖ serial(6) ‖ nonce(4) ‖ content(20)`,
/// which makes every frame unique even though the cipher runs in ECB mode.
public struct LockCommandBuilder {

    private let command: LockCommand
    private let password: String          // exactly 8 chars
    private let aesKey: String            // exactly 16 chars
    private let date: Date
    private let nonceProvider: () -> [UInt8]

    /// - Parameters:
    ///   - date: timestamp baked into the frame. Injectable for deterministic tests.
    ///   - nonceProvider: 4-byte random source. Injectable for deterministic tests.
    public init(
        command: LockCommand,
        password: String,
        aesKey: String,
        date: Date = Date(),
        nonceProvider: @escaping () -> [UInt8] = LockCommandBuilder.secureRandomNonce
    ) {
        self.command = command
        self.password = password
        self.aesKey = aesKey
        self.date = date
        self.nonceProvider = nonceProvider
    }

    public func build() throws -> Data {
        guard password.count == 8 else { throw LockError.invalidPasswordLength }
        guard aesKey.count == 16 else { throw LockError.invalidKeyLength }

        // 20-byte command content.
        var content = Data()
        content.append(password.data(using: .utf8)!)   // 8 bytes
        content.append(command.operationByte)           // 1 byte
        content.append(0x20)                             // 1 byte separator
        content.append(contentsOf: Self.bcdTimestamp(date).prefix(6))  // 6 bytes
        while content.count < 20 { content.append(0x00) }              // pad to 20

        // Assemble the outer frame.
        var frame = Data()
        frame.append(contentsOf: [0xF1, 0x1F])  // header
        frame.append(contentsOf: [0xFF, 0xEE])  // encrypted marker
        frame.append(contentsOf: [0x24, 0x01])  // command id
        frame.append(contentsOf: [0x00, 0x20])  // payload length (32)
        frame.append(try encrypt(content))
        frame.append(checksum(of: Array(frame.dropFirst(2))))
        frame.append(contentsOf: [0xF2, 0x2F])  // tail

        return frame
    }

    // MARK: - Private

    private func encrypt(_ content: Data) throws -> Data {
        var payload = Data()

        let crc = content.crc16CCITT()
        payload.append(UInt8(crc >> 8))
        payload.append(UInt8(crc & 0xFF))

        payload.append(contentsOf: Self.bcdTimestamp(date).prefix(6))  // incrementing serial
        payload.append(contentsOf: nonceProvider().prefix(4))          // random nonce
        payload.append(content)

        return try AES128.encrypt(payload, key: aesKey)
    }

    /// Two's-complement-style checksum with the firmware's `> 0xF0` correction.
    private func checksum(of bytes: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for byte in bytes { sum = sum &+ byte }
        sum = ~sum &+ 1
        if sum > 0xF0 { sum -= 16 }
        return sum
    }

    /// Encodes `yyMMddHHmmss` as 6 packed BCD bytes.
    static func bcdTimestamp(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss"
        let string = formatter.string(from: date)

        var bytes = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex) ?? string.endIndex
            if let value = Int(string[index..<next]) {
                bytes.append(UInt8((value / 10) << 4) | UInt8(value % 10))
            }
            index = next
        }
        return bytes
    }

    public static func secureRandomNonce() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
        return bytes
    }
}
