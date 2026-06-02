//
//  Data+Hex.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation

public extension Data {
    /// Uppercase, unseparated hex representation, e.g. `Data([0xF1, 0x1F]).hexString == "F11F"`.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    /// Parses a hex string (spaces ignored) into bytes. Invalid byte pairs are skipped.
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let byte = UInt8(cleaned[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        self = Data(bytes)
    }
}
