//
//  SmartLockManager.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation
import CoreBluetooth

public protocol SmartLockManagerDelegate: AnyObject {
    func smartLockDidConnect(_ manager: SmartLockManager)
    func smartLockDidDisconnect(_ manager: SmartLockManager)
    func smartLock(_ manager: SmartLockManager, didReceive telemetry: LockTelemetry)
    func smartLock(_ manager: SmartLockManager, didFailWith error: Error)
}

/// End-to-end driver for a BLE smart padlock: discovery → connect → encrypted
/// command → decoded telemetry. Composes ``BLEPeripheralClient`` (transport),
/// ``LockCommandBuilder`` (outbound framing) and ``LockResponseParser`` (inbound
/// reassembly + decryption).
public final class SmartLockManager {

    public struct Credentials {
        public let password: String   // 8 chars
        public let aesKey: String     // 16 chars
        public init(password: String, aesKey: String) {
            self.password = password
            self.aesKey = aesKey
        }
    }

    public weak var delegate: SmartLockManagerDelegate?

    private let credentials: Credentials
    private let client: BLEPeripheralClient
    private let parser: LockResponseParser

    public init(credentials: Credentials, deviceNamePrefix: String) {
        self.credentials = credentials
        self.client = BLEPeripheralClient(
            configuration: .init(targetNamePrefix: deviceNamePrefix)
        )
        self.parser = LockResponseParser(aesKey: credentials.aesKey)
        self.client.delegate = self
    }

    // MARK: - Public API

    public func connect() {
        parser.reset()
        client.startScanning()
    }

    public func disconnect() {
        client.disconnect()
    }

    public func send(_ command: LockCommand) {
        do {
            let frame = try LockCommandBuilder(
                command: command,
                password: credentials.password,
                aesKey: credentials.aesKey
            ).build()
            client.send(frame)
        } catch {
            delegate?.smartLock(self, didFailWith: error)
        }
    }

    public func unlock() { send(.unlock) }
    public func lock()   { send(.lock) }
    public func refreshStatus() { send(.status) }
}

// MARK: - BLEPeripheralClientDelegate

extension SmartLockManager: BLEPeripheralClientDelegate {
    public func bleClient(_ client: BLEPeripheralClient, didChange state: CBManagerState) {}

    public func bleClient(_ client: BLEPeripheralClient, didDiscover peripheral: CBPeripheral, rssi: NSNumber, advertised: AdvertisedState) {}

    public func bleClientDidConnect(_ client: BLEPeripheralClient) {
        delegate?.smartLockDidConnect(self)
    }

    public func bleClientDidDisconnect(_ client: BLEPeripheralClient) {
        delegate?.smartLockDidDisconnect(self)
    }

    public func bleClientDidReady(_ client: BLEPeripheralClient) {
        // Characteristics are ready; pull initial state.
        refreshStatus()
    }

    public func bleClient(_ client: BLEPeripheralClient, didReceive data: Data) {
        if let telemetry = parser.consume(data) {
            delegate?.smartLock(self, didReceive: telemetry)
        }
    }

    public func bleClient(_ client: BLEPeripheralClient, didFailWith error: BLEError) {
        delegate?.smartLock(self, didFailWith: error)
    }
}
