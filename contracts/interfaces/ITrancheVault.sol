// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITrancheVault {
    // State variables (auto-generated getters)
    function underlyingToken() external view returns (address);
    function oracleManager() external view returns (address);

    // Liquidation hooks
    function burnLToken(address user, uint256 tokenId, uint256 balance) external;
    function burnLTokenFromLiquidation(address user, uint256 tokenId, uint256 balance) external; // keeping both for safety if one is needed

    // Auction hooks
    function transferUnderlying(address receiver, uint256 underlyingAmountInWei) external;
    function burnSToken(address kpr, uint256 stableAmount) external;

    function getUserTokenIds(address user) external view returns (uint256[] memory);
    function getLTokenInfo(
        address user,
        uint256 tokenId,
        uint256 currentPriceInWei
    ) external view returns (
        uint256 balance,
        uint256 grossNavInWei,
        uint256 netNavInWei,
        uint256 totalValueInWei,
        uint256 totalNetValueInWei,
        uint256 accruedInterestInWei
    );
}
