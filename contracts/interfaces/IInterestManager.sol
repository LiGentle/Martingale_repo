// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInterestManager {
    function recordPosition(address user, uint256 tokenId, uint256 sAmountInWei, uint256 lAmountInWei) external;
    function previewAccruedInterest(address user, uint256 tokenId) external view returns (uint256);
    function updatePosition(address user, uint256 tokenId, uint256 burnPercentageInBps) external returns (uint256);
}
