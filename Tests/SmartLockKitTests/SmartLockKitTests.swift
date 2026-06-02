import XCTest
@testable import SmartLockKit

final class HexTests: XCTestCase {
    func testHexStringRoundTrip() {
        let data = Data([0xF1, 0x1F, 0x00, 0xAB])
        XCTAssertEqual(data.hexString, "F11F00AB")
        XCTAssertEqual(Data(hex: "f1 1f 00 ab"), data)
    }
}

final class CRC16Tests: XCTestCase {
    /// Standard CRC-16/CCITT-FALSE check value for "123456789".
    func testStandardCheckValue() {
        let crc = Data("123456789".utf8).crc16CCITT()
        XCTAssertEqual(crc, 0x29B1)
    }

    func testEmptyInputIsInitialValue() {
        XCTAssertEqual(Data().crc16CCITT(), 0xFFFF)
    }
}

final class AES128Tests: XCTestCase {
    private let key = "0123456789ABCDEF"   // 16 bytes

    func testRejectsWrongKeyLength() {
        XCTAssertThrowsError(try AES128.encrypt(Data([0, 1, 2, 3]), key: "short"))
    }

    func testEncryptionIsDeterministicInECB() throws {
        let plaintext = Data(repeating: 0x41, count: 32)  // 2 blocks
        let a = try AES128.encrypt(plaintext, key: key)
        let b = try AES128.encrypt(plaintext, key: key)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, plaintext)
    }

    func testDifferentKeysProduceDifferentCiphertext() throws {
        let plaintext = Data(repeating: 0x41, count: 16)
        let a = try AES128.encrypt(plaintext, key: "0123456789ABCDEF")
        let b = try AES128.encrypt(plaintext, key: "FEDCBA9876543210")
        XCTAssertNotEqual(a, b)
    }
}

final class LockCommandBuilderTests: XCTestCase {
    private let password = "12345678"          // 8 chars
    private let aesKey = "0123456789ABCDEF"     // 16 chars
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let fixedNonce: () -> [UInt8] = { [0xDE, 0xAD, 0xBE, 0xEF] }

    private func builder(_ command: LockCommand) -> LockCommandBuilder {
        LockCommandBuilder(command: command, password: password, aesKey: aesKey,
                           date: fixedDate, nonceProvider: fixedNonce)
    }

    func testFrameStructure() throws {
        let frame = try builder(.unlock).build()
        let bytes = [UInt8](frame)

        XCTAssertEqual(bytes.count, 43)
        XCTAssertEqual(Array(bytes[0...1]), [0xF1, 0x1F], "header")
        XCTAssertEqual(Array(bytes[2...3]), [0xFF, 0xEE], "encrypted marker")
        XCTAssertEqual(Array(bytes[4...5]), [0x24, 0x01], "command id")
        XCTAssertEqual(Array(bytes[6...7]), [0x00, 0x20], "payload length = 32")
        XCTAssertEqual(Array(bytes.suffix(2)), [0xF2, 0x2F], "tail")
    }

    func testDeterministicWithFixedInputs() throws {
        let a = try builder(.lock).build()
        let b = try builder(.lock).build()
        XCTAssertEqual(a, b)
    }

    func testDifferentCommandsDifferOnTheWire() throws {
        let unlock = try builder(.unlock).build()
        let lock = try builder(.lock).build()
        XCTAssertNotEqual(unlock, lock)
    }

    func testRejectsBadCredentialLengths() {
        XCTAssertThrowsError(try LockCommandBuilder(command: .unlock, password: "short", aesKey: aesKey).build())
        XCTAssertThrowsError(try LockCommandBuilder(command: .unlock, password: password, aesKey: "short").build())
    }

    func testBCDTimestampEncoding() {
        // 2023-11-14 22:13:20 UTC → "231114221320" depends on local TZ; assert BCD packing rule instead.
        let bytes = LockCommandBuilder.bcdTimestamp(fixedDate)
        XCTAssertEqual(bytes.count, 6)
        for byte in bytes {
            XCTAssertLessThanOrEqual(byte >> 4, 9, "high nibble is a decimal digit")
            XCTAssertLessThanOrEqual(byte & 0x0F, 9, "low nibble is a decimal digit")
        }
    }
}

final class LockResponseParserTests: XCTestCase {
    func testWaitsForCompleteFrame() {
        let parser = LockResponseParser(aesKey: "0123456789ABCDEF")
        // Start marker but no end marker yet → nil.
        XCTAssertNil(parser.consume(Data([0xF3, 0x3F, 0x01, 0x02])))
    }

    func testBatteryCurveBounds() {
        XCTAssertEqual(LockResponseParser.batteryPercentage(millivolts: 2900), 0)
        XCTAssertEqual(LockResponseParser.batteryPercentage(millivolts: 4300), 100)
        let mid = LockResponseParser.batteryPercentage(millivolts: 3900)
        XCTAssertTrue((0...100).contains(mid))
    }

    func testBigEndianInt() {
        XCTAssertEqual(LockResponseParser.beInt([0x00, 0x00, 0x01, 0x00]), 256)
        XCTAssertEqual(LockResponseParser.beInt([0x01, 0x00, 0x00, 0x00]), 16_777_216)
    }
}
