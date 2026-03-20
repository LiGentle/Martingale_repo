import type { UiState } from "../internal/ui/types.js";
import type { BatchInitializeEvent, BeginNextBatchEvent, CallExecutionStateCompleteEvent, CallExecutionStateInitializeEvent, ContractAtExecutionStateInitializeEvent, DeploymentCompleteEvent, DeploymentExecutionStateCompleteEvent, DeploymentExecutionStateInitializeEvent, DeploymentInitializeEvent, DeploymentParameters, DeploymentStartEvent, EncodeFunctionCallExecutionStateInitializeEvent, ExecutionEventListener, NetworkInteractionRequestEvent, OnchainInteractionBumpFeesEvent, OnchainInteractionDroppedEvent, OnchainInteractionReplacedByUserEvent, OnchainInteractionTimeoutEvent, ReadEventArgExecutionStateInitializeEvent, ReconciliationWarningsEvent, RunStartEvent, SendDataExecutionStateCompleteEvent, SendDataExecutionStateInitializeEvent, SetModuleIdEvent, SetStrategyEvent, StaticCallCompleteEvent, StaticCallExecutionStateCompleteEvent, StaticCallExecutionStateInitializeEvent, TransactionConfirmEvent, TransactionPrepareSendEvent, TransactionSendEvent, WipeApplyEvent } from "@nomicfoundation/ignition-core";
import type { UserInterruptionManager } from "hardhat/types/user-interruptions";
export declare class PrettyEventHandler implements ExecutionEventListener {
    private readonly _userInterruptions;
    private readonly _deploymentParams;
    private readonly _disableOutput;
    private _uiState;
    /**
     * @param _userInterruptions Hardhat's UserInterruptionManager.
     *  It must only be `undefined` for testing. Note: Every listener that prints
     *  something to the terminal should use the function _uninterrupted.
     * @param _deploymentParams The deployment parameters.
     * @param _disableOutput A boolean to disable the output.
     */
    constructor(_userInterruptions: UserInterruptionManager | undefined, _deploymentParams?: DeploymentParameters, _disableOutput?: boolean);
    get state(): UiState;
    set state(uiState: UiState);
    deploymentStart(event: DeploymentStartEvent): Promise<void>;
    deploymentInitialize(event: DeploymentInitializeEvent): Promise<void>;
    runStart(_event: RunStartEvent): Promise<void>;
    beginNextBatch(_event: BeginNextBatchEvent): Promise<void>;
    wipeApply(event: WipeApplyEvent): Promise<void>;
    deploymentExecutionStateInitialize(event: DeploymentExecutionStateInitializeEvent): Promise<void>;
    deploymentExecutionStateComplete(event: DeploymentExecutionStateCompleteEvent): Promise<void>;
    callExecutionStateInitialize(event: CallExecutionStateInitializeEvent): Promise<void>;
    callExecutionStateComplete(event: CallExecutionStateCompleteEvent): Promise<void>;
    staticCallExecutionStateInitialize(event: StaticCallExecutionStateInitializeEvent): Promise<void>;
    staticCallExecutionStateComplete(event: StaticCallExecutionStateCompleteEvent): Promise<void>;
    sendDataExecutionStateInitialize(event: SendDataExecutionStateInitializeEvent): Promise<void>;
    sendDataExecutionStateComplete(event: SendDataExecutionStateCompleteEvent): Promise<void>;
    contractAtExecutionStateInitialize(event: ContractAtExecutionStateInitializeEvent): Promise<void>;
    readEventArgumentExecutionStateInitialize(event: ReadEventArgExecutionStateInitializeEvent): Promise<void>;
    encodeFunctionCallExecutionStateInitialize(event: EncodeFunctionCallExecutionStateInitializeEvent): Promise<void>;
    batchInitialize(event: BatchInitializeEvent): Promise<void>;
    networkInteractionRequest(_event: NetworkInteractionRequestEvent): Promise<void>;
    transactionPrepareSend(_event: TransactionPrepareSendEvent): Promise<void>;
    transactionSend(_event: TransactionSendEvent): Promise<void>;
    transactionConfirm(_event: TransactionConfirmEvent): Promise<void>;
    staticCallComplete(_event: StaticCallCompleteEvent): Promise<void>;
    onchainInteractionBumpFees(event: OnchainInteractionBumpFeesEvent): Promise<void>;
    onchainInteractionDropped(_event: OnchainInteractionDroppedEvent): Promise<void>;
    onchainInteractionReplacedByUser(_event: OnchainInteractionReplacedByUserEvent): Promise<void>;
    onchainInteractionTimeout(_event: OnchainInteractionTimeoutEvent): Promise<void>;
    deploymentComplete(event: DeploymentCompleteEvent): Promise<void>;
    reconciliationWarnings(event: ReconciliationWarningsEvent): Promise<void>;
    setModuleId(event: SetModuleIdEvent): Promise<void>;
    setStrategy(event: SetStrategyEvent): Promise<void>;
    private _setFutureStatusInitializedAndRedisplayBatch;
    private _setFutureStatusCompleteAndRedisplayBatch;
    private _setFutureStatusAndRedisplayBatch;
    private _applyUpdateToBatchFuture;
    private _getFutureStatusFromEventResult;
    private _applyResultToBatches;
    private _hasUpdatedResult;
    private _redisplayCurrentBatch;
    private _clearCurrentLine;
    private _clearUpToHeight;
    /**
     * Runs the function `f` without being interrupted by any user interruption,
     * as long as the userInterruptions parameter was provided to the constructor.
     * If it hasn't been provided, it just runs `f`.
     */
    private _uninterrupted;
}
//# sourceMappingURL=pretty-event-handler.d.ts.map