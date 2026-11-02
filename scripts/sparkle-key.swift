// Kite's update signing key (Sparkle EdDSA, docs/updates.md).
//
//   swift scripts/sparkle-key.swift            prints the public key of ~/.kite-secrets/sparkle-ed25519,
//                                              creating the key first if there's none
//   swift scripts/sparkle-key.swift PATH       the same for another key file
//
// The file holds the base64 32-byte private seed, the format Sparkle's sign_update --ed-key-file
// reads (generate_keys -x writes the same). It's a file rather than Sparkle's keychain item so
// release.sh signs without keychain prompts. Lose it and installed Kites can't take updates any
// more, so back it up (1Password). The public key goes in Resources/Info.plist as SUPublicEDKey.
import CryptoKit
import Foundation

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSString(string: "~/.kite-secrets/sparkle-ed25519").expandingTildeInPath
let url = URL(fileURLWithPath: path)
let fm = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let key: Curve25519.Signing.PrivateKey
if fm.fileExists(atPath: path) {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          seed.count == 32,
          let existing = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    else { fail("\(path) isn't a base64 32-byte EdDSA seed") }
    key = existing
} else {
    key = Curve25519.Signing.PrivateKey()
    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Created 0600 before anything is written to it.
        guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            fail("couldn't create \(path)")
        }
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: url)
    } catch {
        fail("couldn't write \(path): \(error)")
    }
    FileHandle.standardError.write(Data("Created \(path). Back it up: without it, installed Kites can't be updated.\n".utf8))
}
print(key.publicKey.rawRepresentation.base64EncodedString())
