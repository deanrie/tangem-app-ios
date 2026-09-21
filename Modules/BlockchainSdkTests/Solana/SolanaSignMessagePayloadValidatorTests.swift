//
//  SolanaSignMessagePayloadValidatorTests.swift
//  BlockchainSdkTests
//
//  Copyright © 2026 Tangem AG. All rights reserved.
//

import Foundation
import Testing
import SolanaSwift
@testable import BlockchainSdk

struct SolanaSignMessagePayloadValidatorTests {
    /// A real serialized legacy Solana transaction (same fixture as `SolanaALTTransactionTests`).
    private let transactionHex = "0100080befc956a850e3dd3f49236e234b1f9ef97bc6bd4cc8f62a453790ffda215c1cd0821b8e94014ee6179f4f349149401a94a74d4281b05a970eac460873cceb87a4c76c5cd238bbbfb6dd0710fa4c2600927397d05613993c05683aac49d53f8eac00000000000000000000000000000000000000000000000000000000000000008c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f8590306466fe5211732ffecadba72c39be7bc8ce5bbc5f7126b2c439b3a40000000ce010e60afedb22717bd63192f54145a3f965a33bb82d2c7029eb2ce1e208264f3427828d631f9d2badf483574a565ca7cbb91f2a47ceb92f80e35774d7d1a3e069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f0000000000106ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9075f6bf3d3f1b96038bd4fb6118f911f2e79e302f49be06db48d2625ce121a0adefd993aecf44c450683b40e5af4972eb6c0dd557c4cfcea6fde7c1081c16c0f0405000502a086010005000903e803000000000000040600010008030900070c030a0809020007060004070749181ec828051c0777e5234fbb00e1f50500000000b722f30000000000b722f3000000000027368368010000000000000100000000000000033683681800000020150000000001000000"

    @Test
    func rejectsASerializedTransaction() {
        #expect(SolanaSignMessagePayloadValidator.looksLikeTransaction(Data(hexString: transactionHex)))
    }

    @Test
    func rejectsTheBareMessageOfATransaction() throws {
        let transaction = try VersionedTransaction.deserialize(data: Data(hexString: transactionHex))
        let messageData = try transaction.message.value.serialize()

        #expect(SolanaSignMessagePayloadValidator.looksLikeTransaction(messageData))
    }

    @Test(arguments: [
        "Sign in with your wallet to example.com",
        "nonce: 9f2c1a",
        "",
    ])
    func allowsPlainTextMessages(text: String) {
        #expect(!SolanaSignMessagePayloadValidator.looksLikeTransaction(Data(text.utf8)))
    }
}
