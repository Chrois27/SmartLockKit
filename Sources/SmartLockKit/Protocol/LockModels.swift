//
//  LockModels.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation

/// High-level operations supported by the lock firmware.
public enum LockCommand {
    case unlock
    case lock
    case status
    case clearRFID
    case factoryReset

    /// Operation opcode placed inside the (encrypted) command payload.
    public var operationByte: UInt8 {
        switch self {
        case .unlock:       return 0x30
        case .lock:         return 0x31
        case .status:       return 0x32
        case .clearRFID:    return 0x34
        case .factoryReset: return 0x36
        }
    }
}

/// Result code returned by the lock for the last operation.
public enum ReplyStatus: UInt8 {
    case invalidPassword     = 0x00
    case ok                  = 0x01
    case shackleNotClosed    = 0x02
    case serialNumberError   = 0x04
    case crcError            = 0x05
    case otherError          = 0x06

    public var isSuccess: Bool { self == .ok }
}

/// Mechanical lock position.
public enum LockState: UInt8 {
    case unlocked = 0x30
    case locked   = 0x31
    case unknown  = 0xFF
}

/// Tamper / alarm state reported alongside telemetry.
public enum AlarmState: UInt8 {
    case normal       = 0x30
    case caseBreached = 0x31
    case shackleCut   = 0x32
    case unknown      = 0xFF
}

public enum LockError: Error {
    case invalidPasswordLength
    case invalidKeyLength
    case malformedResponse
}
