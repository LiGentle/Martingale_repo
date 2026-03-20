import readline from "node:readline";
import { DeploymentResultType, ExecutionEventResultType, } from "@nomicfoundation/ignition-core";
import { calculateBatchDisplay } from "../internal/ui/helpers/calculate-batch-display.js";
import { calculateDeployingModulePanel } from "../internal/ui/helpers/calculate-deploying-module-panel.js";
import { calculateDeploymentCompleteDisplay } from "../internal/ui/helpers/calculate-deployment-complete-display.js";
import { calculateStartingMessage } from "../internal/ui/helpers/calculate-starting-message.js";
import { wasAnythingExecuted } from "../internal/ui/helpers/was-anything-executed.js";
import { UiFutureStatusType, UiStateDeploymentStatus, } from "../internal/ui/types.js";
export class PrettyEventHandler {
    _userInterruptions;
    _deploymentParams;
    _disableOutput;
    _uiState = {
        status: UiStateDeploymentStatus.UNSTARTED,
        chainId: null,
        moduleName: null,
        deploymentDir: null,
        batches: [],
        currentBatch: 0,
        result: null,
        warnings: [],
        isResumed: null,
        maxFeeBumps: 0,
        disableFeeBumping: null,
        gasBumps: {},
        strategy: null,
    };
    /**
     * @param _userInterruptions Hardhat's UserInterruptionManager.
     *  It must only be `undefined` for testing. Note: Every listener that prints
     *  something to the terminal should use the function _uninterrupted.
     * @param _deploymentParams The deployment parameters.
     * @param _disableOutput A boolean to disable the output.
     */
    constructor(_userInterruptions, _deploymentParams = {}, _disableOutput = false) {
        this._userInterruptions = _userInterruptions;
        this._deploymentParams = _deploymentParams;
        this._disableOutput = _disableOutput;
    }
    get state() {
        return this._uiState;
    }
    set state(uiState) {
        this._uiState = uiState;
    }
    async deploymentStart(event) {
        return this._uninterrupted(async () => {
            this.state = {
                ...this.state,
                status: UiStateDeploymentStatus.DEPLOYING,
                moduleName: event.moduleName,
                deploymentDir: event.deploymentDir,
                isResumed: event.isResumed,
                maxFeeBumps: event.maxFeeBumps,
                disableFeeBumping: event.disableFeeBumping,
            };
            process.stdout.write(calculateStartingMessage(this.state));
        });
    }
    async deploymentInitialize(event) {
        return this._uninterrupted(async () => {
            this.state = {
                ...this.state,
                chainId: event.chainId,
            };
        });
    }
    async runStart(_event) {
        return this._uninterrupted(async () => {
            this._clearCurrentLine();
            console.log(calculateDeployingModulePanel(this.state));
        });
    }
    async beginNextBatch(_event) {
        return this._uninterrupted(async () => {
            // rerender the previous batch
            if (this.state.currentBatch > 0) {
                this._redisplayCurrentBatch();
            }
            this.state = {
                ...this.state,
                currentBatch: this.state.currentBatch + 1,
            };
            if (this.state.currentBatch === 0) {
                return;
            }
            // render the new batch
            console.log(calculateBatchDisplay(this.state).text);
        });
    }
    async wipeApply(event) {
        return this._uninterrupted(async () => {
            const batches = [];
            for (const batch of this.state.batches) {
                const futureBatch = [];
                for (const future of batch) {
                    if (future.futureId === event.futureId) {
                        continue;
                    }
                    else {
                        futureBatch.push(future);
                    }
                }
                batches.push(futureBatch);
            }
            this.state = {
                ...this.state,
                batches,
            };
        });
    }
    async deploymentExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusInitializedAndRedisplayBatch(event);
        });
    }
    async deploymentExecutionStateComplete(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusCompleteAndRedisplayBatch(event);
        });
    }
    async callExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusInitializedAndRedisplayBatch(event);
        });
    }
    async callExecutionStateComplete(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusCompleteAndRedisplayBatch(event);
        });
    }
    async staticCallExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusInitializedAndRedisplayBatch(event);
        });
    }
    async staticCallExecutionStateComplete(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusCompleteAndRedisplayBatch(event);
        });
    }
    async sendDataExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusInitializedAndRedisplayBatch(event);
        });
    }
    async sendDataExecutionStateComplete(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusCompleteAndRedisplayBatch(event);
        });
    }
    async contractAtExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusAndRedisplayBatch(event.futureId, {
                type: UiFutureStatusType.SUCCESS,
            });
        });
    }
    async readEventArgumentExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusAndRedisplayBatch(event.futureId, {
                type: UiFutureStatusType.SUCCESS,
            });
        });
    }
    async encodeFunctionCallExecutionStateInitialize(event) {
        return this._uninterrupted(async () => {
            this._setFutureStatusAndRedisplayBatch(event.futureId, {
                type: UiFutureStatusType.SUCCESS,
            });
        });
    }
    async batchInitialize(event) {
        return this._uninterrupted(async () => {
            const batches = [];
            for (const batch of event.batches) {
                const futureBatch = [];
                for (const futureId of batch) {
                    futureBatch.push({
                        futureId,
                        status: {
                            type: UiFutureStatusType.UNSTARTED,
                        },
                    });
                }
                batches.push(futureBatch);
            }
            this.state = {
                ...this.state,
                batches,
            };
        });
    }
    async networkInteractionRequest(_event) { }
    async transactionPrepareSend(_event) { }
    async transactionSend(_event) { }
    async transactionConfirm(_event) { }
    async staticCallComplete(_event) { }
    async onchainInteractionBumpFees(event) {
        return this._uninterrupted(async () => {
            if (this._uiState.gasBumps[event.futureId] === undefined) {
                this._uiState.gasBumps[event.futureId] = 0;
            }
            this._uiState.gasBumps[event.futureId] += 1;
            this._redisplayCurrentBatch();
        });
    }
    async onchainInteractionDropped(_event) { }
    async onchainInteractionReplacedByUser(_event) { }
    async onchainInteractionTimeout(_event) { }
    async deploymentComplete(event) {
        return this._uninterrupted(async () => {
            this.state = {
                ...this.state,
                status: UiStateDeploymentStatus.COMPLETE,
                result: event.result,
                batches: this._applyResultToBatches(this.state.batches, event.result),
            };
            // If batches where executed, rerender the last batch
            if (wasAnythingExecuted(this.state)) {
                this._redisplayCurrentBatch();
            }
            else {
                // Otherwise only the completion panel will be shown so clear
                // the Starting Ignition line.
                this._clearCurrentLine();
            }
            console.log(calculateDeploymentCompleteDisplay(event, this.state));
        });
    }
    async reconciliationWarnings(event) {
        return this._uninterrupted(async () => {
            this.state = {
                ...this.state,
                warnings: [...this.state.warnings, ...event.warnings],
            };
        });
    }
    async setModuleId(event) {
        return this._uninterrupted(async () => {
            this.state = {
                ...this.state,
                moduleName: event.moduleName,
            };
        });
    }
    async setStrategy(event) {
        return this._uninterrupted(async () => {
            this.state = {
                ...this.state,
                strategy: event.strategy,
            };
        });
    }
    _setFutureStatusInitializedAndRedisplayBatch({ futureId, }) {
        this._setFutureStatusAndRedisplayBatch(futureId, {
            type: UiFutureStatusType.UNSTARTED,
        });
    }
    _setFutureStatusCompleteAndRedisplayBatch({ futureId, result, }) {
        this._setFutureStatusAndRedisplayBatch(futureId, this._getFutureStatusFromEventResult(result));
        this.state = {
            ...this.state,
        };
    }
    _setFutureStatusAndRedisplayBatch(futureId, status) {
        const updatedFuture = {
            futureId,
            status,
        };
        this.state = {
            ...this.state,
            batches: this._applyUpdateToBatchFuture(updatedFuture),
        };
        this._redisplayCurrentBatch();
    }
    _applyUpdateToBatchFuture(updatedFuture) {
        const batches = [];
        for (const batch of this.state.batches) {
            const futureBatch = [];
            for (const future of batch) {
                if (future.futureId === updatedFuture.futureId) {
                    futureBatch.push(updatedFuture);
                }
                else {
                    futureBatch.push(future);
                }
            }
            batches.push(futureBatch);
        }
        return batches;
    }
    _getFutureStatusFromEventResult(result) {
        switch (result.type) {
            case ExecutionEventResultType.SUCCESS: {
                return {
                    type: UiFutureStatusType.SUCCESS,
                    result: result.result,
                };
            }
            case ExecutionEventResultType.ERROR: {
                return {
                    type: UiFutureStatusType.ERRORED,
                    message: result.error,
                };
            }
            case ExecutionEventResultType.HELD: {
                return {
                    type: UiFutureStatusType.HELD,
                    heldId: result.heldId,
                    reason: result.reason,
                };
            }
        }
    }
    _applyResultToBatches(batches, result) {
        const newBatches = [];
        for (const oldBatch of batches) {
            const newBatch = [];
            for (const future of oldBatch) {
                const updatedFuture = this._hasUpdatedResult(future.futureId, result);
                newBatch.push(updatedFuture ?? future);
            }
            newBatches.push(newBatch);
        }
        return newBatches;
    }
    _hasUpdatedResult(futureId, result) {
        if (result.type !== DeploymentResultType.EXECUTION_ERROR) {
            return null;
        }
        const failed = result.failed.find((f) => f.futureId === futureId);
        if (failed !== undefined) {
            const f = {
                futureId,
                status: {
                    type: UiFutureStatusType.ERRORED,
                    message: failed.error,
                },
            };
            return f;
        }
        const timedout = result.timedOut.find((f) => f.futureId === futureId);
        if (timedout !== undefined) {
            const f = {
                futureId,
                status: {
                    type: UiFutureStatusType.TIMEDOUT,
                },
            };
            return f;
        }
        return null;
    }
    _redisplayCurrentBatch() {
        if (!this._disableOutput) {
            const { height, text: batch } = calculateBatchDisplay(this.state);
            this._clearUpToHeight(height);
            console.log(batch);
        }
    }
    _clearCurrentLine() {
        readline.clearLine(process.stdout, 0);
        readline.cursorTo(process.stdout, 0);
    }
    _clearUpToHeight(height) {
        readline.moveCursor(process.stdout, 0, -height);
        readline.clearScreenDown(process.stdout);
    }
    /**
     * Runs the function `f` without being interrupted by any user interruption,
     * as long as the userInterruptions parameter was provided to the constructor.
     * If it hasn't been provided, it just runs `f`.
     */
    _uninterrupted(f) {
        if (this._userInterruptions !== undefined) {
            return this._userInterruptions.uninterrupted(f);
        }
        return f();
    }
}
//# sourceMappingURL=pretty-event-handler.js.map