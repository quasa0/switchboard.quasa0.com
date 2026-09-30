import CryptoKit
import Foundation

// Generate once outside the checkout. Never print or place the private seed in Git.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/update-key.swift PRIVATE_FILE PUBLIC_FILE")
}
let privateURL = URL(fileURLWithPath: CommandLine.arguments[1])
let publicURL = URL(fileURLWithPath: CommandLine.arguments[2])
let manager = FileManager.default
let key: Curve25519.Signing.PrivateKey
if manager.fileExists(atPath: privateURL.path) {
    let encoded = try String(contentsOf: privateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded) else { fatalError("Invalid signing seed") }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
} else {
    try manager.createDirectory(at: privateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    key = Curve25519.Signing.PrivateKey()
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: privateURL, options: .withoutOverwriting)
}
try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
let publicText = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
if manager.fileExists(atPath: publicURL.path) {
    guard try String(contentsOf: publicURL, encoding: .utf8) == publicText else { fatalError("Public key does not match. Do not rotate an installed update key.") }
} else {
    try manager.createDirectory(at: publicURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(publicText.utf8).write(to: publicURL, options: .withoutOverwriting)
}
print("Signing key ready. Private seed remains outside the checkout.")
