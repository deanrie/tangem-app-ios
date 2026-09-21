//
//  SolanaSignMessagePayloadValidator.swift
//  BlockchainSdk
//
//  Copyright © 2026 Tangem AG. All rights reserved.
//

import Foundation
import SolanaSwift

/// Guards `solana_signMessage`: a message that deserializes as a Solana transaction / message must be refused,
/// otherwise a dApp can have the user "sign a message" that is in fact a fund-moving transaction — the raw
/// ed25519 signature is identical to the one `solana_signTransaction` would produce, but without the
/// transaction summary and Blockaid simulation the transaction path gets. This mirrors Phantom / Solflare /
/// Backpack, and — unlike inspecting the instructions — needs no understanding of the transaction, only the
/// answer to "do these bytes parse as a transaction at all?".
public enum SolanaSignMessagePayloadValidator {
    /// `true` if `data` deserializes as a legacy or versioned Solana transaction, or as a bare message.
    public static func looksLikeTransaction(_ data: Data) -> Bool {
        guard !data.isEmpty else {
            return false
        }

        // A full transaction (compact-array of signatures + message) — strict enough on its own.
        if let transaction = try? VersionedTransaction.deserialize(data: data, isIncludeSignature: true),
           !transaction.message.value.staticAccountKeys.isEmpty {
            return true
        }

        // A bare serialized message — this is what the signMessage attack carries. The legacy decoder is lenient
        // and will "parse" arbitrary text, so require an exact re-serialization round-trip and at least one account
        // key. That is still "do these bytes ARE a message", not an inspection of the instructions.
        if let message = try? VersionedMessage.deserialize(data: data),
           let reserialized = try? message.value.serialize(),
           reserialized == data,
           !message.value.staticAccountKeys.isEmpty {
            return true
        }

        return false
    }
}
