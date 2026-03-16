// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITreasury {
    function withdraw(address to, uint256 amount) external;

    function getBalance() external view returns (uint256);
}
