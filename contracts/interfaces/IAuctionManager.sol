// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAuctionManager {
    function startAuction(
        uint256 valueToBeBurned,
        address originalOwner,
        uint256 tokenId,
        uint256 underlyingValueToUser,
        address triggerer
    ) external returns (uint256 auctionId);
}