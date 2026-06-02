//
//  CRC16.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation

public extension Data {
    /// CRC-16/CCITT-FALSE: polynomial `0x1021`, initial value `0xFFFF`, no reflection.
    ///
    /// Used by the lock frame to protect the payload before encryption.
    /// The standard check value for the ASCII string `"123456789"` is `0x29B1`.
    func crc16CCITT() -> UInt16 {
        var crc: UInt16 = 0xFFFF
        let polynomial: UInt16 = 0x1021

        for byte in self {
            for i in 0..<8 {
                let bit = UInt16((byte >> (7 - i)) & 1)
                let msb = (crc >> 15) & 1
                crc <<= 1
                if (msb ^ bit) == 1 {
                    crc ^= polynomial
                }
            }
        }
        return crc
    }
}
