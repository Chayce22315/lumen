import Foundation
import Synchronization
import LumenFoundation
import LumenCore
import LumenPlugins
import LumenTestSupport

/// A stand-in digest for tests of this engine (the real SHA-256 lives in LumenKnowledge and is
/// exercised by the application tests): 64 hex digits from four seeded FNV-1a passes.
let testDigest: @Sendable (Data) -> String = { data in
    var output = ""
    for seed in [UInt64(0xcbf2_9ce4_8422_2325), 0x8422_2325_cbf2_9ce4, 0x1234_5678_9abc_def0, 0x0fed_cba9_8765_4321] {
        var hash = seed
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        output += String(format: "%016llx", hash)
    }
    return output
}

/// A fake Ed25519: the "signature" is a digest of key and message, so it verifies only for the
/// exact payload and key it was made for. It tests the plumbing (what is signed, what is
/// compared), not cryptography; CryptoKit's verifier is used on Apple platforms.
struct FakeSigner: Sendable {
    let publicKey: Data

    init(seed: UInt8) {
        publicKey = Data((0..<32).map { UInt8(truncatingIfNeeded: Int($0) &* 7 &+ Int(seed)) })
    }

    func sign(_ message: Data) -> Data {
        FakeSigner.signature(publicKey: publicKey, message: message)
    }

    static func signature(publicKey: Data, message: Data) -> Data {
        let first = testDigest(publicKey + message)
        let second = testDigest(message + publicKey)
        return Data(hex: first + second)
    }
}

struct FakeSignatureVerifier: PluginSignatureVerifier {
    func isValidSignature(_ signature: Data, of message: Data, publicKey: Data) throws -> Bool {
        signature == FakeSigner.signature(publicKey: publicKey, message: message)
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

/// Builds `.lumenplugin` files for tests. The default is the sample package: a weekly-review
/// plugin with a workflow template, two commands, a prompt and a webhook step.
struct TestPackage {
    var manifest: [String: JSONValue]
    var signer: FakeSigner? = FakeSigner(seed: 1)
    var formatVersion: JSONValue = 1
    var extraEnvelope: [String: JSONValue] = [:]

    static let triggerID = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    static func sample(id: String = "com.example.weekly-review", version: String = "1.0.0") -> TestPackage {
        TestPackage(manifest: [
            "schemaVersion": 1,
            "id": .string(id),
            "name": "Weekly Review",
            "version": .string(version),
            "publisher": ["name": "Example Co", "url": "https://example.com"],
            "description": "Plan the week ahead every Friday.",
            "minimumLumenVersion": "1.0.0",
            "capabilities": ["contributeWorkflowTemplates", "contributeCommands", "contributeAssistantPrompts", "contributeAutomationActions", "network"],
            "network": ["hosts": ["hooks.example.com"]],
            "contributions": [
                "workflows": [[
                    "id": "weekly",
                    "name": "Weekly review",
                    "summary": "Adds a review task.",
                    "trigger": ["type": "manual"],
                    "graph": ["nodes": [["id": .string(triggerID), "title": "Start", "kind": ["type": "trigger"]]], "edges": []],
                ]],
                "commands": [
                    ["id": "open-today", "title": "Review today", "keywords": ["review"], "action": ["type": "openLink", "url": "lumen://tasks/today"]],
                    ["id": "run-weekly", "title": "Run weekly review", "action": ["type": "runWorkflow", "workflow": "weekly"]],
                ],
                "prompts": [["id": "plan", "title": "Plan my week", "prompt": "Look at my tasks and propose a plan for the week."]],
                "webhooks": [[
                    "id": "post-summary",
                    "title": "Post summary",
                    "url": "https://hooks.example.com/lumen",
                    "fields": [["name": "text", "title": "Text", "multiline": true, "required": true]],
                ]],
            ],
        ])
    }

    var id: String { manifest["id"]?.stringValue ?? "" }

    mutating func set(_ key: String, _ value: JSONValue?) {
        manifest[key] = value
    }

    /// The manifest bytes exactly as they will be signed.
    var payload: Data {
        (try? JSONCoding.encoder.encode(JSONValue.object(manifest))) ?? Data()
    }

    var data: Data {
        let payload = self.payload
        var envelope: [String: JSONValue] = [
            "format": "app.lumen.plugin",
            "formatVersion": formatVersion,
            "payload": .string(payload.base64EncodedString()),
        ]
        if let signer {
            envelope["signature"] = [
                "algorithm": "ed25519",
                "publicKey": .string(signer.publicKey.base64EncodedString()),
                "value": .string(signer.sign(PluginPackageFormat.signedMessage(payload: payload)).base64EncodedString()),
            ]
        }
        for (key, value) in extraEnvelope { envelope[key] = value }
        return (try? JSONCoding.encoder.encode(JSONValue.object(envelope))) ?? Data()
    }
}

let testReader = PluginPackageReader(verifier: FakeSignatureVerifier(), digest: testDigest)
