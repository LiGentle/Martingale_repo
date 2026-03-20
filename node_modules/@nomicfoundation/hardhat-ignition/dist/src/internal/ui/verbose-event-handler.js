import { ExecutionEventNetworkInteractionType, ExecutionEventResultType, } from "@nomicfoundation/ignition-core";
export class VerboseEventHandler {
    async deploymentInitialize(event) {
        console.log(`Deployment initialized for chainId: ${event.chainId}`);
    }
    async wipeApply(event) {
        console.log(`Removing the execution of future ${event.futureId}`);
    }
    async deploymentExecutionStateInitialize(event) {
        console.log(`Starting to execute the deployment future ${event.futureId}`);
    }
    async deploymentExecutionStateComplete(event) {
        switch (event.result.type) {
            case ExecutionEventResultType.SUCCESS: {
                return console.log(`Successfully completed the execution of deployment future ${event.futureId} with address ${event.result.result ?? "undefined"}`);
            }
            case ExecutionEventResultType.ERROR: {
                return console.log(`Execution of future ${event.futureId} failed with reason: ${event.result.error}`);
            }
            case ExecutionEventResultType.HELD: {
                return console.log(`Execution of future ${event.futureId}/${event.result.heldId} held with reason: ${event.result.reason}`);
            }
        }
    }
    async callExecutionStateInitialize(event) {
        console.log(`Starting to execute the call future ${event.futureId}`);
    }
    async callExecutionStateComplete(event) {
        switch (event.result.type) {
            case ExecutionEventResultType.SUCCESS: {
                return console.log(`Successfully completed the execution of call future ${event.futureId}`);
            }
            case ExecutionEventResultType.ERROR: {
                return console.log(`Execution of call future ${event.futureId} failed with reason: ${event.result.error}`);
            }
            case ExecutionEventResultType.HELD: {
                return console.log(`Execution of call future ${event.futureId}/${event.result.heldId} held with reason: ${event.result.reason}`);
            }
        }
    }
    async staticCallExecutionStateInitialize(event) {
        console.log(`Starting to execute the static call future ${event.futureId}`);
    }
    async staticCallExecutionStateComplete(event) {
        switch (event.result.type) {
            case ExecutionEventResultType.SUCCESS: {
                return console.log(`Successfully completed the execution of static call future ${event.futureId} with result ${event.result.result ?? "undefined"}`);
            }
            case ExecutionEventResultType.ERROR: {
                return console.log(`Execution of static call future ${event.futureId} failed with reason: ${event.result.error}`);
            }
            case ExecutionEventResultType.HELD: {
                return console.log(`Execution of static call future ${event.futureId}/${event.result.heldId} held with reason: ${event.result.reason}`);
            }
        }
    }
    async sendDataExecutionStateInitialize(event) {
        console.log(`Started to execute the send data future ${event.futureId}`);
    }
    async sendDataExecutionStateComplete(event) {
        switch (event.result.type) {
            case ExecutionEventResultType.SUCCESS: {
                return console.log(`Successfully completed the execution of send data future ${event.futureId} in tx ${event.result.result ?? "undefined"}`);
            }
            case ExecutionEventResultType.ERROR: {
                return console.log(`Execution of future ${event.futureId} failed with reason: ${event.result.error}`);
            }
            case ExecutionEventResultType.HELD: {
                return console.log(`Execution of send future ${event.futureId}/${event.result.heldId} held with reason: ${event.result.reason}`);
            }
        }
    }
    async contractAtExecutionStateInitialize(event) {
        console.log(`Executed contract at future ${event.futureId}`);
    }
    async readEventArgumentExecutionStateInitialize(event) {
        console.log(`Executed read event argument future ${event.futureId} with result ${event.result.result ?? "undefined"}`);
    }
    async encodeFunctionCallExecutionStateInitialize(event) {
        console.log(`Executed encode function call future ${event.futureId} with result ${event.result.result ?? "undefined"}`);
    }
    async networkInteractionRequest(event) {
        if (event.networkInteractionType ===
            ExecutionEventNetworkInteractionType.ONCHAIN_INTERACTION) {
            console.log(`New onchain interaction requested for future ${event.futureId}`);
        }
        else {
            console.log(`New static call requested for future ${event.futureId}`);
        }
    }
    async transactionPrepareSend(event) {
        console.log(`Transaction about to be sent for onchain interaction of future ${event.futureId}`);
    }
    async transactionSend(event) {
        console.log(`Transaction ${event.hash} sent for onchain interaction of future ${event.futureId}`);
    }
    async transactionConfirm(event) {
        console.log(`Transaction ${event.hash} confirmed`);
    }
    async staticCallComplete(event) {
        console.log(`Static call completed for future ${event.futureId}`);
    }
    async onchainInteractionBumpFees(event) {
        console.log(`A transaction with higher fees will be sent for onchain interaction of future ${event.futureId}`);
    }
    async onchainInteractionDropped(event) {
        console.log(`Transactions for onchain interaction of future ${event.futureId} has been dropped and will be resent`);
    }
    async onchainInteractionReplacedByUser(event) {
        console.log(`Transactions for onchain interaction of future ${event.futureId} has been replaced by the user and the onchain interaction execution will start again`);
    }
    async onchainInteractionTimeout(event) {
        console.log(`Onchain interaction of future ${event.futureId} failed due to being resent too many times and not having confirmed`);
    }
    async batchInitialize(event) {
        console.log(`Starting execution for batches: ${JSON.stringify(event.batches)}`);
    }
    async deploymentStart(_event) {
        console.log(`Starting execution for new deployment`);
    }
    async beginNextBatch(_event) {
        console.log(`Starting execution for next batch`);
    }
    async deploymentComplete(_event) {
        console.log(`Deployment complete`);
    }
    async reconciliationWarnings(event) {
        console.log(`Deployment produced reconciliation warnings:\n${event.warnings.join("  -")}`);
    }
    async setModuleId(event) {
        console.log(`Starting validation for module: ${event.moduleName}`);
    }
    async setStrategy(event) {
        console.log(`Starting execution with strategy: ${event.strategy}`);
    }
    async runStart(_event) {
        console.log("Execution run starting");
    }
}
//# sourceMappingURL=verbose-event-handler.js.map