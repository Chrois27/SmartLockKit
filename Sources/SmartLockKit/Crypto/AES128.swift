//
//  AES128.swift
//  SmartLockKit
//
//  Created by Chris Choi.
//

import Foundation
import CommonCrypto

public enum AES128Error: Error {
    case invalidKeyLength
    case encryptionFailed
    case decryptionFailed
}

/// AES-128 / ECB block cipher matching the lock firmware's configuration.
///
/// - Important: ECB has no diffusion on its own. The frame layer compensates by
///   prefixing every payload with a CRC, an incrementing serial number and a
///   random nonce before encryption (see ``LockCommandBuilder``), so identical
///   commands never produce identical ciphertext on the wire.
public enum AES128 {

    /// The key must be exactly 16 UTF-8 bytes (AES-128).
    private static func keyData(from key: String) throws -> Data {
        guard let data = key.data(using: .utf8), data.count == kCCKeySizeAES128 else {
            throw AES128Error.invalidKeyLength
        }
        return data
    }

    /// Encrypts block-aligned plaintext in ECB mode (no padding added).
    public static func encrypt(_ data: Data, key: String) throws -> Data {
        let keyData = try keyData(from: key)
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var produced = 0

        let status = keyData.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, keyData.count,
                    nil,
                    dataBytes.baseAddress, data.count,
                    &buffer, bufferSize, &produced
                )
            }
        }

        guard status == kCCSuccess else { throw AES128Error.encryptionFailed }
        return Data(buffer.prefix(produced))
    }

    /// Decrypts ECB ciphertext, stripping PKCS#7 padding if present.
    public static func decrypt(_ data: Data, key: String) throws -> Data {
        let keyData = try keyData(from: key)
        let bufferSize = (data.count + kCCBlockSizeAES128) & ~(kCCBlockSizeAES128 - 1)
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var produced = 0

        let status = keyData.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, kCCKeySizeAES128,
                    nil,
                    dataBytes.baseAddress, data.count,
                    &buffer, bufferSize, &produced
                )
            }
        }

        guard status == kCCSuccess else { throw AES128Error.decryptionFailed }
        return Data(buffer.prefix(produced))
    }
}
