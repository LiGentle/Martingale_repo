# Sample Hardhat 3 Beta Project (`node:test` and `viem`)

This project showcases a Hardhat 3 Beta project using the native Node.js test runner (`node:test`) and the `viem` library for Ethereum interactions.

To learn more about the Hardhat 3 Beta, please visit the [Getting Started guide](https://hardhat.org/docs/getting-started#getting-started-with-hardhat-3). To share your feedback, join our [Hardhat 3 Beta](https://hardhat.org/hardhat3-beta-telegram-group) Telegram group or [open an issue](https://github.com/NomicFoundation/hardhat/issues/new) in our GitHub issue tracker.

## Project Overview

This example project includes:

- A simple Hardhat configuration file.
- Foundry-compatible Solidity unit tests.
- TypeScript integration tests using [`node:test`](nodejs.org/api/test.html), the new Node.js native test runner, and [`viem`](https://viem.sh/).
- Examples demonstrating how to connect to different types of networks, including locally simulating OP mainnet.

## Usage

### Running Tests

To run all the tests in the project, execute the following command:

```shell
npx hardhat test
```

You can also selectively run the Solidity or `node:test` tests:

```shell
npx hardhat test solidity
npx hardhat test nodejs
```

### Make a deployment to Sepolia

This project includes an example Ignition module to deploy the contract. You can deploy this module to a locally simulated chain or to Sepolia.

To run the deployment to a local chain:

```shell
npx hardhat ignition deploy ignition/modules/Counter.ts
```

To run the deployment to Sepolia, you need an account with funds to send the transaction. The provided Hardhat configuration includes a Configuration Variable called `SEPOLIA_PRIVATE_KEY`, which you can use to set the private key of the account you want to use.

You can set the `SEPOLIA_PRIVATE_KEY` variable using the `hardhat-keystore` plugin or by setting it as an environment variable.

To set the `SEPOLIA_PRIVATE_KEY` config variable using `hardhat-keystore`:

```shell
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
```

After setting the variable, you can run the deployment with the Sepolia network:

```shell
npx hardhat ignition deploy --network sepolia ignition/modules/Counter.ts
```

```mermaid
flowchart TD
    Mint[1. Call mint & collateralize Underlying]
    Mint --> Hold[2. Receive S + L Token]
    
    Hold --> Check{3. Position Status}
    
    %% Branch 1: Normal Exit
    Check -->|Active Exit| Burn[4a. Call burn]
    Burn --> PayInterest[5a. Deduct accumulated interest]
    PayInterest --> Repay[6a. Burn S + Burn L]
    Repay --> End1([7a. Retrieve Underlying])
    
    %% Branch 2: Liquidation
    Check -->|Net Value drops below threshold| Bark[4b. Bot triggers bark]
    Bark --> BurnL[5b. Burn L Token to stop interest]
    BurnL --> Auction[6b. Assets transferred to Auction]
    Auction --> Bid[7b. Liquidator pays S to buy Underlying]
    Bid --> End2([8b. Remaining Underlying returned to user])

    %% Branch 3: Early Liquidity (AMM Swap)
    Hold --> SwapAMM[4c. Swap S to U in AMM Pool]
    SwapAMM --> End3([5c. Obtain U])

    %% Styling for different branches
    classDef branchA fill:#d4edda,stroke:#28a745,color:#155724,stroke-width:2px
    classDef branchB fill:#f8d7da,stroke:#dc3545,color:#721c24,stroke-width:2px
    classDef branchC fill:#cce5ff,stroke:#007bff,color:#004085,stroke-width:2px

    class Burn,PayInterest,Repay,End1 branchA
    class Bark,BurnL,Auction,Bid,End2 branchB
    class SwapAMM,End3 branchC
```