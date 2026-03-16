// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStableSwapAMM {
    function reserve0() external view returns (uint256);
    function reserve1() external view returns (uint256);
    function multiplier0() external view returns (uint256);
    function multiplier1() external view returns (uint256);
}