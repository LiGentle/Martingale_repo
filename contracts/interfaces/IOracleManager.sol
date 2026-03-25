// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracleManager {
    function getLatestPriceView() external view returns (uint256 price, uint256 timestamp, bool isValid);
    function getNoDelayPrice()  external view returns (uint256 priceXAU) ;
}