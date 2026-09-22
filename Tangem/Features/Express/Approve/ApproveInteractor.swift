//
//  ApproveInteractor.swift
//  Tangem
//
//  Created on 2026.
//  Copyright © 2026 Tangem AG. All rights reserved.
//

import Foundation
import Combine
import BlockchainSdk
import TangemExpress
import TangemFoundation
import TangemLocalization
import TangemMacro

final class ApproveInteractor {
    // MARK: - Publishers

    var approveFeePublisher: AnyPublisher<TokenFee, Never> {
        tokenFeeProvidersManager.selectedTokenFeePublisher
    }

    /// `true` while the calldata is being rebuilt for a newly selected policy. The approve button must
    /// stay disabled during this window, otherwise the previous policy's calldata would be signed.
    var isRecalculatingPolicyPublisher: AnyPublisher<Bool, Never> {
        isRecalculatingPolicySubject.eraseToAnyPublisher()
    }

    /// Emits the policy the calldata is still consistent with when a recalculation fails, so the UI
    /// can revert its selection instead of showing a policy that is not what would be signed.
    var policyRecalculationFailedPublisher: AnyPublisher<BSDKApprovePolicy, Never> {
        policyRecalculationFailedSubject.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    private let approveAmount: Decimal
    private let allowanceService: any AllowanceService
    private let approveTransactionDispatcher: any TransactionDispatcher
    private let tokenFeeProvidersManager: any TokenFeeProvidersManager
    private let analyticsLogger: any SendApproveAnalyticsLogger
    private weak var output: ApproveOutput?

    // MARK: - State

    private(set) var approveInteractorState: ApproveInteractorState
    private var currentPolicy: BSDKApprovePolicy
    /// The policy `approveInteractorState` was built for. Diverges from `currentPolicy` only while a
    /// recalculation is in flight; `sendApproveTransaction` refuses to sign when they differ.
    private var statePolicy: BSDKApprovePolicy
    private var recalculateApproveFeeTask: Task<Void, Never>?
    private let isRecalculatingPolicySubject = CurrentValueSubject<Bool, Never>(false)
    private let policyRecalculationFailedSubject = PassthroughSubject<BSDKApprovePolicy, Never>()

    // MARK: - Init

    init(
        approveInteractorState: ApproveInteractorState,
        initialPolicy: BSDKApprovePolicy,
        approveAmount: Decimal,
        allowanceService: any AllowanceService,
        approveTransactionDispatcher: any TransactionDispatcher,
        tokenFeeProvidersManager: any TokenFeeProvidersManager,
        analyticsLogger: any SendApproveAnalyticsLogger,
        output: ApproveOutput
    ) {
        self.approveInteractorState = approveInteractorState
        currentPolicy = initialPolicy
        statePolicy = initialPolicy
        self.approveAmount = approveAmount
        self.allowanceService = allowanceService
        self.approveTransactionDispatcher = approveTransactionDispatcher
        self.tokenFeeProvidersManager = tokenFeeProvidersManager
        self.analyticsLogger = analyticsLogger
        self.output = output

        tokenFeeProvidersManager.update(input: approveInteractorState.feeInput)
        tokenFeeProvidersManager.updateFees()
    }

    deinit {
        recalculateApproveFeeTask?.cancel()
    }

    // MARK: - Public

    func logPermissionScreenOpened() {
        analyticsLogger.logPermissionScreenOpened(isRevoke: approveInteractorState.isRevokeAndApprove)
    }

    func updateApprovePolicy(policy: BSDKApprovePolicy) {
        currentPolicy = policy

        recalculateApproveFeeTask?.cancel()
        isRecalculatingPolicySubject.send(true)

        recalculateApproveFeeTask = runTask(in: self) { interactor in
            do {
                let allowanceResult = try await interactor.allowanceService.allowanceState(
                    amount: interactor.approveAmount,
                    spender: interactor.approveInteractorState.approveData.spender,
                    approvePolicy: policy,
                )

                try Task.checkCancellation()

                guard let newState = interactor.makeApproveInteractorState(from: allowanceResult) else {
                    // Allowance is already sufficient (or in progress): the sheet has nothing to sign for
                    // this policy. Treat it like a failure so the UI reverts rather than signing stale data.
                    await runOnMain {
                        interactor.handlePolicyRecalculationFailure(error: nil)
                    }
                    return
                }

                await runOnMain {
                    interactor.approveInteractorState = newState
                    interactor.statePolicy = policy
                    interactor.isRecalculatingPolicySubject.send(false)
                }

                interactor.tokenFeeProvidersManager.update(input: newState.feeInput)
                interactor.tokenFeeProvidersManager.updateFees()
            } catch is CancellationError {
                // Expected: superseded by a newer recalculation, which now owns the "recalculating" flag.
            } catch {
                await runOnMain {
                    interactor.handlePolicyRecalculationFailure(error: error)
                }
            }
        }
    }

    func sendApproveTransaction() async throws {
        // Never sign calldata that was built for a different policy than the one the user sees.
        guard !isRecalculatingPolicySubject.value, currentPolicy == statePolicy else {
            throw ApproveInteractorError.policyOutOfSync
        }

        switch approveInteractorState {
        case .approve(let data):
            try await sendApprove(data: data)
        case .revokeAndApprove(let revoke, let approve, let feeUnit):
            try await sendRevokeAndApprove(revokeData: revoke, approveData: approve, feeUnit: feeUnit)
        }
    }

    func userDidSelectFeeToken(tokenFeeProvider: any TokenFeeProvider) {
        tokenFeeProvidersManager.updateSelectedFeeProvider(feeTokenItem: tokenFeeProvider.feeTokenItem)
        tokenFeeProvidersManager.updateFees()
    }
}

// MARK: - Private

private extension ApproveInteractor {
    /// A recalculation could not produce calldata for the newly selected policy. Keep the previous
    /// (consistent) state, point `currentPolicy` back at it and tell the UI to revert its selection.
    /// Call on the main queue (see `runOnMain` at the call sites).
    func handlePolicyRecalculationFailure(error: Error?) {
        if let error {
            ExpressLogger.error(error: error)
        }

        currentPolicy = statePolicy
        isRecalculatingPolicySubject.send(false)
        policyRecalculationFailedSubject.send(statePolicy)
    }

    func makeApproveInteractorState(from result: AllowanceState) -> ApproveInteractorState? {
        switch result {
        case .permissionRequired(let data):
            return .approve(data: data)
        case .revokeAndPermissionRequired(let revoke, let approve):
            if case .revokeAndApprove(_, _, let feeUnit) = approveInteractorState {
                return .revokeAndApprove(revoke: revoke, approve: approve, feeUnit: feeUnit)
            }
            assertionFailure("Unexpected state transition to revokeAndApprove")
            return .approve(data: approve)
        default:
            return nil
        }
    }

    func sendApprove(data: ApproveTransactionData) async throws {
        let fee = try tokenFeeProvidersManager.selectedTokenFee.value.get()

        analyticsLogger.logSwapButtonPermissionApprove(policy: currentPolicy)
        let result = try await approveTransactionDispatcher.send(
            transaction: .approve(data: data, fee: fee)
        )

        await allowanceService.markApproveTransactionSent(spender: data.spender)

        ExpressLogger.info("Sent the approve transaction with signerType: \(result.signerType), host: \(result.currentHost)")
        analyticsLogger.logApproveTransactionSent(
            policy: currentPolicy,
            signerType: result.signerType,
            currentProviderHost: result.currentHost
        )

        output?.approveDidSendTransaction()
    }

    /// Sends revoke (approve to 0) then approve in one batch.
    /// Required for tokens like USDT on Ethereum that need allowance reset to zero first.
    func sendRevokeAndApprove(revokeData: ApproveTransactionData, approveData: ApproveTransactionData, feeUnit: BSDKFee) async throws {
        ExpressLogger.info("Sending revoke+approve batch for spender: \(approveData.spender)")

        // feeUnit is the 1x revoke fee estimate.
        // Approve tx needs ~2x the gas, so we double gasLimit and amount.
        // Revoke+approve only applies to EVM tokens (e.g. USDT on Ethereum).
        guard let ethParams = feeUnit.parameters as? (any EthereumFeeParameters) else {
            assertionFailure("Revoke+approve flow requires EthereumFeeParameters, got \(type(of: feeUnit.parameters))")
            throw TransactionDispatcherResult.Error.transactionNotFound
        }

        let revokeFee = feeUnit
        let bufferedParams = ethParams.changingGasLimit(to: ethParams.gasLimit * 2)
        var bufferedAmount = feeUnit.amount
        bufferedAmount.value *= 2
        let approveFee = BSDKFee(bufferedAmount, parameters: bufferedParams)

        let transactions: [TransactionDispatcherTransactionType] = [
            .approve(data: revokeData, fee: revokeFee),
            .approve(data: approveData, fee: approveFee),
        ]

        analyticsLogger.logSwapButtonPermissionApprove(policy: currentPolicy)

        let results = try await approveTransactionDispatcher.send(transactions: transactions)

        await allowanceService.markApproveTransactionSent(spender: approveData.spender)

        if let result = results.last {
            ExpressLogger.info("Sent the revoke+approve transactions with signerType: \(result.signerType), host: \(result.currentHost)")
            analyticsLogger.logApproveTransactionSent(
                policy: currentPolicy,
                signerType: result.signerType,
                currentProviderHost: result.currentHost
            )
        }

        output?.approveDidSendTransaction()
    }
}

// MARK: - Errors

enum ApproveInteractorError: LocalizedError {
    /// The selected policy and the built calldata diverged (recalculation in flight or failed).
    case policyOutOfSync

    var errorDescription: String? {
        switch self {
        case .policyOutOfSync:
            return Localization.commonUnknownError
        }
    }
}

// MARK: - ApproveInteractorState

extension ApproveInteractor {
    @CaseFlagable
    enum ApproveInteractorState {
        case approve(data: ApproveTransactionData)
        /// - `feeUnit`: 1x revoke fee estimate, used to build individual tx fees at send time
        case revokeAndApprove(revoke: ApproveTransactionData, approve: ApproveTransactionData, feeUnit: Fee)

        var approveData: ApproveTransactionData {
            switch self {
            case .approve(let data):
                return data
            case .revokeAndApprove(_, let approve, _):
                return approve
            }
        }

        /// Fee input derived from this state. For revoke+approve, fee is estimated against the
        /// revoke tx because the node can't simulate a non-zero approve when on-chain allowance
        /// is already non-zero (USDT will revert).
        var feeInput: TokenFeeProviderInputData {
            switch self {
            case .approve(let data):
                .approve(txData: data.txData, toContractAddress: data.toContractAddress)
            case .revokeAndApprove(let revoke, _, _):
                .approve(txData: revoke.txData, toContractAddress: revoke.toContractAddress, feeMultiplier: .triple)
            }
        }
    }
}

// MARK: - FeeSelectorTokensDataProvider

extension ApproveInteractor: FeeSelectorTokensDataProvider {
    var selectedTokenFeeProvider: any TokenFeeProvider {
        tokenFeeProvidersManager.selectedFeeProvider
    }

    var selectedTokenFeeProviderPublisher: AnyPublisher<any TokenFeeProvider, Never> {
        tokenFeeProvidersManager.selectedFeeProviderPublisher
    }

    var supportedTokenFeeProviders: [any TokenFeeProvider] {
        tokenFeeProvidersManager.tokenFeeProviders.filter { $0.state.isSupported }
    }

    var supportedTokenFeeProvidersPublisher: AnyPublisher<[any TokenFeeProvider], Never> {
        let providers = tokenFeeProvidersManager.tokenFeeProviders

        return Publishers.MergeMany(providers.map(\.statePublisher))
            .map { _ in providers.filter { $0.state.isSupported } }
            .prepend(providers.filter { $0.state.isSupported })
            .removeDuplicates(by: { $0.map(\.feeTokenItem) == $1.map(\.feeTokenItem) })
            .eraseToAnyPublisher()
    }
}
