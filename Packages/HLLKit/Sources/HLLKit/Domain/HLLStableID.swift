import CryptoKit
import Foundation

/// Deterministic IDs keep SwiftUI identity stable when a source is refetched.
public enum HLLStableID {
    public static func make(_ components: some Sequence<String>) -> UUID {
        let bytes = SHA256.hash(data: Data(components.joined(separator: "\u{1F}").utf8))
        var value = Array(bytes.prefix(16))
        value[6] = (value[6] & 0x0F) | 0x50
        value[8] = (value[8] & 0x3F) | 0x80
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5],
                           value[6], value[7], value[8], value[9], value[10], value[11],
                           value[12], value[13], value[14], value[15]))
    }
}
