import Foundation
import CryptoKit

enum EmbeddedResourceVault {
    private static let magic = Array("RVLT3105".utf8)
    private static let headerSize = 16
    private static let entrySize = 48

    static func data(named name: String) -> Data? {
        let digest = Data(SHA256.hash(data: Data(name.utf8)))
        var size: Int = 0
        guard let base = resource_vault_section(&size), size >= headerSize else { return nil }
        let vault = Data(bytes: base, count: size)
        guard Array(vault.prefix(8)) == magic, read32(vault, 8) == 1 else { return nil }
        let count = Int(read32(vault, 12))
        guard headerSize + count * entrySize <= vault.count else { return nil }
        for i in 0..<count {
            let e = headerSize + i * entrySize
            guard vault.subdata(in: e..<(e+32)) == digest else { continue }
            let off = Int(read64(vault, e+32)), len = Int(read64(vault, e+40))
            guard off >= 0, len >= 28, off <= vault.count, len <= vault.count-off else { return nil }
            var keyBytes = [UInt8](repeating: 0, count: 32)
            keyBytes.withUnsafeMutableBufferPointer { if let p=$0.baseAddress { resource_vault_copy_key(p) } }
            defer { for i in keyBytes.indices { keyBytes[i] = 0 } }
            do {
                let key = SymmetricKey(data: Data(keyBytes))
                let box = try ChaChaPoly.SealedBox(combined: vault.subdata(in: off..<(off+len)))
                return try ChaChaPoly.open(box, using: key, authenticating: digest)
            } catch { return nil }
        }
        return nil
    }

    private static func read32(_ d: Data, _ o: Int) -> UInt32 {
        guard o >= 0, o+4 <= d.count else { return .max }
        var v: UInt32 = 0; for i in 0..<4 { v |= UInt32(d[o+i]) << UInt32(i*8) }; return v
    }
    private static func read64(_ d: Data, _ o: Int) -> UInt64 {
        guard o >= 0, o+8 <= d.count else { return .max }
        var v: UInt64 = 0; for i in 0..<8 { v |= UInt64(d[o+i]) << UInt64(i*8) }; return v
    }
}
