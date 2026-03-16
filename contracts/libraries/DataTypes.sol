// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


/// @notice Structure to hold information about a specific token type
struct TokenInfo {
    uint256 underlyingAmountInWei;      // The amount of underlying asset deposited for this token
    uint256 mintPriceInWei;    // The initial mint price (P0)
    uint256 LTVInBps;          // The loan-to-value ratio initially,5_000 (50%)
    uint256 sAmountInWei;       // The amount of sAMount   
    uint256 lAmountInWei;       // The amount of lAmount
    uint256 creationTime;      // actual block.timestamp for dynamic tokens
    bool isLocked;              // Whether the token is currently locked (cannot be withdrawn S or Underlying)
}
    