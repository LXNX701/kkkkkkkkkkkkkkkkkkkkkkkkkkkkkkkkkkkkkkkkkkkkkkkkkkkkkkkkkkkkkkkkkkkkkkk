import Foundation
import CryptoKit

enum EmbeddedPatchVaultError: Error {
    case missingPatch(String)
    case unavailable
    case invalidVault
    case authenticationFailed
}

enum EmbeddedPatchVault {
    private static let magic = Array("PVLT3105".utf8)
    private static let headerSize = 16
    private static let entrySize = 48

    static func data(named fileName: String) throws -> Data {
        guard AuthProtection.shared.hasFeature(fileName: fileName) else {
            throw EmbeddedPatchVaultError.authenticationFailed
        }
        let expectedName = (fileName as NSString).lastPathComponent
        let nameDigest = Data(SHA256.hash(data: Data(expectedName.utf8)))
        let vault = try vaultData()

        guard vault.count >= headerSize,
              Array(vault.prefix(8)) == magic,
              readUInt32LE(vault, at: 8) == 1 else {
            throw EmbeddedPatchVaultError.invalidVault
        }

        let count = Int(readUInt32LE(vault, at: 12))
        guard count >= 0,
              headerSize + count * entrySize <= vault.count else {
            throw EmbeddedPatchVaultError.invalidVault
        }

        for index in 0..<count {
            let entry = headerSize + index * entrySize
            let hashRange = entry..<(entry + 32)
            guard vault.subdata(in: hashRange) == nameDigest else { continue }

            let offset64 = readUInt64LE(vault, at: entry + 32)
            let length64 = readUInt64LE(vault, at: entry + 40)
            guard offset64 <= UInt64(Int.max), length64 <= UInt64(Int.max) else {
                throw EmbeddedPatchVaultError.invalidVault
            }

            let offset = Int(offset64)
            let length = Int(length64)
            guard offset >= 0, length >= 28, offset <= vault.count,
                  length <= vault.count - offset else {
                throw EmbeddedPatchVaultError.invalidVault
            }

            let sealed = vault.subdata(in: offset..<(offset + length))
            return try open(sealed, authenticating: nameDigest)
        }

        throw EmbeddedPatchVaultError.missingPatch(expectedName)
    }

    private static func vaultData() throws -> Data {
        var size: Int = 0
        guard let base = patch_vault_section(&size), size >= headerSize else {
            throw EmbeddedPatchVaultError.unavailable
        }
        return Data(bytes: base, count: size)
    }

    private static func open(_ combined: Data, authenticating digest: Data) throws -> Data {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        keyBytes.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress {
                patch_vault_copy_key(base)
            }
        }
        defer {
            for i in keyBytes.indices { keyBytes[i] = 0 }
        }

        do {
            let key = SymmetricKey(data: Data(keyBytes))
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(box, using: key, authenticating: digest)
        } catch {
            throw EmbeddedPatchVaultError.authenticationFailed
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return UInt32.max }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.index(data.startIndex, offsetBy: offset + i)]) << UInt32(i * 8)
        }
        return value
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return UInt64.max }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[data.index(data.startIndex, offsetBy: offset + i)]) << UInt64(i * 8)
        }
        return value
    }
}
