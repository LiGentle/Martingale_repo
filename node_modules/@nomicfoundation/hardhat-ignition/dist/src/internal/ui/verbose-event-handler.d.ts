import type { BatchInitializeEvent, BeginNextBatchEvent, CallExecutionStateCompleteEvent, CallExecutionStateInitializeEvent, ContractAtExecutionStateInitializeEvent, DeploymentCompleteEvent, DeploymentExecutionStateCompleteEvent, DeploymentExecutionStateInitializeEvent, DeploymentInitializeEvent, DeploymentStartEvent, EncodeFunctionCallExecutionStateInitializeEvent, ExecutionEventListener, NetworkInteractionRequestEvent, OnchainInteractionBumpFeesEvent, OnchainInteractionDroppedEvent, OnchainInteractionReplacedByUserEvent, OnchainInteractionTimeoutEvent, ReadEventArgExecutionStateInitializeEvent, ReconciliationWarningsEvent, RunStartEvent, SendDataExecutionStateCompleteEvent, SendDataExecutionStateInitializeEvent, SetModuleIdEvent, SetStrategyEvent, StaticCallCompleteEvent, StaticCallExecutionStateCompleteEvent, StaticCallExecutionStateInitializeEvent, TransactionConfirmEvent, TransactionPrepareSendEvent, TransactionSendEvent, WipeApplyEvent } from "@nomicfoundation/ignition-core";
export declare class VerboseEventHandler implements ExecutionEventListener {
    deploymentInitialize(event: DeploymentInitializeEvent): Promise<void>;
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
    networkInteractionRequest(event: NetworkInteractionRequestEvent): Promise<void>;
    transactionPrepareSend(event: TransactionPrepareSendEvent): Promise<void>;
    transactionSend(event: TransactionSendEvent): Promise<void>;
    transactionConfirm(event: TransactionConfirmEvent): Promise<void>;
    staticCallComplete(event: StaticCallCompleteEvent): Promise<void>;
    onchainInteractionBumpFees(event: OnchainInteractionBumpFeesEvent): Promise<void>;
    onchainInteractionDropped(event: OnchainInteractionDroppedEvent): Promise<void>;
    onchainInteractionReplacedByUser(event: OnchainInteractionReplacedByUserEvent): Promise<void>;
    onchainInteractionTimeout(event: OnchainInteractionTimeoutEvent): Promise<void>;
    batchInitialize(event: BatchInitializeEvent): Promise<void>;
    deploymentStart(_event: DeploymentStartEvent): Promise<void>;
    beginNextBatch(_event: BeginNextBatchEvent): Promise<void>;
    deploymentComplete(_event: DeploymentCompleteEvent): Promise<void>;
    reconciliationWarnings(event: ReconciliationWarningsEvent): Promise<void>;
    setModuleId(event: SetModuleIdEvent): Promise<void>;
    setStrategy(event: SetStrategyEvent): Promise<void>;
    runStart(_event: RunStartEvent): Promise<void>;
}
//# sourceMappingURL=verbose-event-handler.d.ts.map