// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/DataTypes.sol";

interface ILiquidationManager {
    function checkFreezeStatus(address user, uint256 tokenId) external view returns (bool);
    function checkLockStatus(address user, uint256 tokenId) external view returns (bool);
}