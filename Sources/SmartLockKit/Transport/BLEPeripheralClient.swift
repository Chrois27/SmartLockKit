//
//  BLEPeripheralClient.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation
import CoreBluetooth

/// Decoded fields from the lock's BLE advertisement (manufacturer-specific TLV).
public struct AdvertisedState: Equatable {
    public var voltage: Double?     // volts
    public var battery: Int?        // percent
    public var status: UInt8?
    public var macAddress: String?
}

public protocol BLEPeripheralClientDelegate: AnyObject {
    func bleClient(_ client: BLEPeripheralClient, didChange state: CBManagerState)
    func bleClient(_ client: BLEPeripheralClient, didDiscover peripheral: CBPeripheral, rssi: NSNumber, advertised: AdvertisedState)
    func bleClientDidConnect(_ client: BLEPeripheralClient)
    func bleClientDidDisconnect(_ client: BLEPeripheralClient)
    func bleClientDidReady(_ client: BLEPeripheralClient)
    func bleClient(_ client: BLEPeripheralClient, didReceive data: Data)
    func bleClient(_ client: BLEPeripheralClient, didFailWith error: BLEError)
}

public enum BLEError: Error {
    case unsupported
    case unauthorized
    case poweredOff
    case connectionTimeout
    case unknown
}

/// A focused CoreBluetooth Central that connects to a single Nordic-UART-style
/// peripheral, enables notifications and ships writes in MTU-sized chunks.
///
/// Hardware specifics (target name, UART UUIDs, timeouts) are configurable so the
/// client is reusable across devices that speak the Nordic UART Service profile.
public final class BLEPeripheralClient: NSObject {

    public struct Configuration {
        /// Substring matched against the peripheral / advertised local name.
        public var targetNamePrefix: String
        public var serviceUUID: CBUUID
        public var txCharacteristicUUID: CBUUID   // central → peripheral
        public var rxCharacteristicUUID: CBUUID   // peripheral → central (notify)
        public var connectionTimeout: TimeInterval
        public var writeChunkSize: Int

        /// Defaults to the Nordic UART Service (NUS) UUIDs.
        public init(
            targetNamePrefix: String,
            serviceUUID: CBUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
            txCharacteristicUUID: CBUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
            rxCharacteristicUUID: CBUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
            connectionTimeout: TimeInterval = 10.0,
            writeChunkSize: Int = 20
        ) {
            self.targetNamePrefix = targetNamePrefix
            self.serviceUUID = serviceUUID
            self.txCharacteristicUUID = txCharacteristicUUID
            self.rxCharacteristicUUID = rxCharacteristicUUID
            self.connectionTimeout = connectionTimeout
            self.writeChunkSize = writeChunkSize
        }
    }

    public weak var delegate: BLEPeripheralClientDelegate?
    public let configuration: Configuration

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var connectionTimer: Timer?
    private var isBusy = false

    public init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    public var isScanning: Bool { central.isScanning }

    // MARK: - Public API

    /// Begins scanning for the configured peripheral. No-op until Bluetooth is powered on.
    public func startScanning() {
        guard !isBusy, central.state == .poweredOn else { return }
        isBusy = true
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    public func stopScanning() {
        central.stopScan()
        isBusy = false
    }

    public func disconnect() {
        connectionTimer?.invalidate()
        connectionTimer = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
    }

    /// Writes data to the TX characteristic, fragmented to `writeChunkSize`.
    public func send(_ data: Data) {
        guard let peripheral, let characteristic = txCharacteristic else { return }
        var offset = 0
        while offset < data.count {
            let length = min(configuration.writeChunkSize, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
            offset += length
            Thread.sleep(forTimeInterval: 0.05)   // pace writes for slow firmware
        }
    }

    // MARK: - Helpers

    private func connect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        central.connect(peripheral, options: nil)
        connectionTimer = Timer.scheduledTimer(withTimeInterval: configuration.connectionTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.disconnect()
            self.isBusy = false
            self.delegate?.bleClient(self, didFailWith: .connectionTimeout)
        }
    }

    private func mapError(_ state: CBManagerState) -> BLEError? {
        switch state {
        case .poweredOn:     return nil
        case .poweredOff:    return .poweredOff
        case .unauthorized:  return .unauthorized
        case .unsupported:   return .unsupported
        default:             return .unknown
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEPeripheralClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.bleClient(self, didChange: central.state)
        if central.state != .poweredOn, let error = mapError(central.state) {
            stopScanning()
            delegate?.bleClient(self, didFailWith: error)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let prefix = configuration.targetNamePrefix
        let matches = (peripheral.name?.contains(prefix) ?? false) || (localName?.contains(prefix) ?? false)
        guard matches else { return }

        let advertised = Self.parseAdvertisement(advertisementData)
        delegate?.bleClient(self, didDiscover: peripheral, rssi: RSSI, advertised: advertised)
        stopScanning()
        connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionTimer?.invalidate()
        peripheral.delegate = self
        peripheral.discoverServices([configuration.serviceUUID])
        delegate?.bleClientDidConnect(self)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        self.peripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        delegate?.bleClientDidDisconnect(self)
    }

    /// Parses the manufacturer-specific advertisement TLV blocks
    /// (`len, type, value…`) into a typed ``AdvertisedState``.
    static func parseAdvertisement(_ data: [String: Any]) -> AdvertisedState {
        var state = AdvertisedState()
        guard let raw = data[CBAdvertisementDataManufacturerDataKey] as? Data else { return state }
        let bytes = [UInt8](raw)

        var i = 0
        while i + 1 < bytes.count {
            let len = bytes[i]
            let type = bytes[i + 1]
            switch (len, type) {
            case (0x03, 0x01) where i + 3 < bytes.count:
                state.voltage = Double(UInt16(bytes[i + 2]) << 8 | UInt16(bytes[i + 3])) * 0.01
                i += Int(len) + 1
            case (0x03, 0x02) where i + 3 < bytes.count:
                state.battery = Int(Double(UInt16(bytes[i + 2]) << 8 | UInt16(bytes[i + 3])) / 100.0)
                i += Int(len) + 1
            case (0x02, 0x03) where i + 2 < bytes.count:
                state.status = bytes[i + 2]
                i += Int(len) + 1
            case (0x07, 0x04) where i + 7 < bytes.count:
                state.macAddress = bytes[(i + 2)...(i + 7)].map { String(format: "%02X", $0) }.joined(separator: ":")
                i += Int(len) + 1
            default:
                i += 1
            }
        }
        return state
    }
}

// MARK: - CBPeripheralDelegate

extension BLEPeripheralClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(
                [configuration.txCharacteristicUUID, configuration.rxCharacteristicUUID],
                for: service
            )
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == configuration.txCharacteristicUUID {
                txCharacteristic = characteristic
            }
            if characteristic.uuid == configuration.rxCharacteristicUUID {
                rxCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if txCharacteristic != nil && rxCharacteristic != nil {
            delegate?.bleClientDidReady(self)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == configuration.rxCharacteristicUUID,
              let data = characteristic.value else { return }
        delegate?.bleClient(self, didReceive: data)
    }
}
