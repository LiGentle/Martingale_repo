// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../tokens/LeverageToken.sol";
import "../interfaces/ITrancheVault.sol";
import "../interfaces/IOracleManager.sol";
import "../interfaces/IAuctionManager.sol";
import "../config/ProtocolConfig.sol";
import "../libraries/MathUtils.sol";
import "../libraries/DataTypes.sol";
import "../interfaces/ILiquidationManager.sol";

contract LiquidationManager is ReentrancyGuard, ILiquidationManager {
    using MathUtils for uint256;

    // ================= State Variables =================

    /// @notice Protocol configuration contract (immutable)
    ProtocolConfig public immutable config;

    /// @notice Leverage token contract (immutable)
    LeverageToken public immutable leverageToken;

    /// @notice Tranche vault interface
    ITrancheVault public trancheVault;

    /// @notice Auction manager interface
    IAuctionManager public auctionManager;

    // ================= Data Structures =================

    /// @notice User liquidation status for specific token positions
    /// @param isLocked Whether the position has protection enabled (cannot be liquidated)
    struct UserLiquidationStatus {
        bool isLocked;
    }

    /// @notice Mapping of user liquidation status by user address and token ID
    mapping(address => mapping(uint256 => UserLiquidationStatus)) public userLiquidationStatus;

    // ================= Events =================

    /// @notice Emitted when the tranche vault address is updated
    /// @param oldVault Previous vault address
    /// @param newVault New vault address
    event TrancheVaultChanged(address indexed oldVault, address indexed newVault);

    /// @notice Emitted when the auction manager address is updated
    /// @param oldAuctionManager Previous auction manager address
    /// @param newAuctionManager New auction manager address
    event AuctionManagerUpdated(address indexed oldAuctionManager, address indexed newAuctionManager);

    /// @notice Emitted when a liquidation is triggered
    /// @param user Address of the liquidated user
    /// @param tokenId Token ID being liquidated
    /// @param valueToBeBurned Amount of stable tokens to be burned
    /// @param auctionId ID of the created auction
    event Barked(address indexed user, uint256 indexed tokenId, uint256 valueToBeBurned, uint256 auctionId);

    /// @notice Emitted when protection is enabled on a position
    /// @param user Address of the user
    /// @param tokenId Token ID being protected
    event Protect(address indexed user, uint256 indexed tokenId);

    /// @notice Emitted when protection is removed from a position
    /// @param user Address of the user
    /// @param tokenId Token ID losing protection
    event LiftProtection(address indexed user, uint256 indexed tokenId);

    // ================= Modifiers =================

    /// @notice Modifier to check if liquidation is enabled in protocol config
    modifier liquidationEnabled() {
        require(config.liquidationEnabled(), "LM/ Liquidation not enabled");
        _;
    }

    /// @notice Modifier to restrict function execution to specific roles
    /// @param role The role identifier from ProtocolConfig
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "LM/ Caller missing required role");
        _;
    }

    // ================= Constructor =================
    constructor(
        address _config,
        address _LTokenAddress
    ){

        require(_config != address(0), "LM/ Config cannot be zero address");
        require(_LTokenAddress != address(0), "LM/ LeverageToken cannot be zero address");

        config = ProtocolConfig(_config);
        leverageToken = LeverageToken(_LTokenAddress);

    }


    function setTrancheVault(address _newVault) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_newVault != address(0), "LM/ Invalid address");
        emit TrancheVaultChanged(address(trancheVault), _newVault);
        trancheVault = ITrancheVault(_newVault);
    }

    function setAuctionManager(address _auctionManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_auctionManager != address(0), "LM/ Invalid address");
        emit AuctionManagerUpdated(address(auctionManager), _auctionManager);
        auctionManager = IAuctionManager(_auctionManager);
    }

    // ================= View Functions =================


    /// @notice Checks if a position has protection enabled
    /// @param user Address of the user
    /// @param tokenId Token ID to check
    /// @return isLocked Whether the position is protected
    function checkLockStatus(address user, uint256 tokenId) public view returns (bool isLocked) {
        isLocked = userLiquidationStatus[user][tokenId].isLocked;
    }

    // ================= Protection Management =================

    /// @notice Enables liquidation protection on a position by freezing stable tokens
    /// @param tokenId Token ID to protect
    /// @dev User must have positive balance and NAV must be above liquidation boundary.
    /// Freezes stable tokens equivalent to the position's S token amount.
    /// @custom:error NoBalance if user has no tokens
    /// @custom:error PositionProtected if position is already protected
    /// @custom:error NavTooLow if NAV is below liquidation boundary
    function protectL(uint256 tokenId) public nonReentrant liquidationEnabled() {
        address user = msg.sender;
        uint256 balance = leverageToken.balanceOf(user, tokenId);
        require(balance > 0, "LM/ No token to protect");
        require(!userLiquidationStatus[user][tokenId].isLocked, "LM/ The token is already under protection");

        (
            ,
            ,
            ,
            uint256 sAmountInWei,
            uint256 lAmountInWei,
            ,
        ) = leverageToken.getTokenInfo(tokenId);

        uint256 leverageRatio = lAmountInWei.wdiv(sAmountInWei);
        uint256 liquidationBoundary = config.liquidationThreshold().wdiv(leverageRatio);
        uint256 nav = _calculateNetAssetValue(user, tokenId);
        require(nav > liquidationBoundary, "LM/ Tokens with NAV below liquidation boundary cannot be protected");

        trancheVault.freezeStable(user, sAmountInWei);
        userLiquidationStatus[user][tokenId].isLocked = true;
        emit Protect(user, tokenId);
    }

    /// @notice Removes liquidation protection from a position and unfreezes stable tokens
    /// @param tokenId Token ID to remove protection from
    /// @dev User must have positive balance and NAV must be above liquidation boundary.
    /// Unfreezes stable tokens equivalent to the position's S token amount.
    /// @custom:error NoBalance if user has no tokens
    /// @custom:error PositionNotProtected if position is not under protection
    /// @custom:error NavTooLow if NAV is below liquidation boundary
    function liftProtection(uint256 tokenId) public nonReentrant liquidationEnabled() {
        address user = msg.sender;
        uint256 balance = leverageToken.balanceOf(user, tokenId);
        require(balance > 0, "LM/ No tokens");
        require(userLiquidationStatus[user][tokenId].isLocked, "LM/ The tokens are not under protection");

        (
            ,
            ,
            ,
            uint256 sAmountInWei,
            uint256 lAmountInWei,
            ,
        ) = leverageToken.getTokenInfo(tokenId);

        uint256 leverageRatio = lAmountInWei.wdiv(sAmountInWei);
        uint256 liquidationBoundary = config.liquidationThreshold().wdiv(leverageRatio);
        uint256 nav = _calculateNetAssetValue(user, tokenId);
        require(nav > liquidationBoundary, "LM/ Tokens with NAV below liquidation boundary cannot be lifted from protection");

        userLiquidationStatus[user][tokenId].isLocked = false;
        trancheVault.unfreezeStable(user, sAmountInWei);
        emit LiftProtection(user, tokenId);
    }


    // ================= Liquidation Functions =================

    /// @notice Triggers liquidation for a position (similar to MakerDAO's bark function)
    /// @param user Address of the user being liquidated
    /// @param tokenId Token ID to liquidate
    /// @param kpr Keeper address receiving the incentive
    /// @dev Only callable when liquidation is enabled. Creates an auction for the liquidated position.
    /// @custom:error AuctionManagerNotSet if auction manager is not configured
    /// @custom:error TrancheVaultNotSet if tranche vault is not configured
    /// @custom:error ZeroAddress if user or keeper address is zero
    /// @custom:error PositionProtected if position is protected
    /// @custom:error NoTokens if user has no tokens
    /// @custom:error NavAboveThreshold if NAV is above liquidation threshold
    /// @custom:error NullAuction if value to be burned is zero
    function bark(
        address user,
        uint256 tokenId,
        address kpr
    ) external liquidationEnabled nonReentrant {
        require(address(auctionManager) != address(0), "LM/ Set auction address first!");
        require(address(trancheVault) != address(0), "LM/ Set Vault address first!");
        require(user != address(0), "LM/ Invalid user address");
        require(kpr != address(0), "LM/ Invalid keeper address");
        require(!userLiquidationStatus[user][tokenId].isLocked, "LM/ The token is under protection");
        uint256 balance = leverageToken.balanceOf(user, tokenId);
        require(balance > 0, "LM/ No tokens");

        // Get token information from LeverageToken contract
        (
            , // underlyingAmountInWei
            , // mintPriceInWei
            , // LTVInBps
            uint256 sAmountInWei,
            uint256 lAmountInWei,
            , // creationTime
        ) = leverageToken.getTokenInfo(tokenId);

        // Calculate liquidation boundary and check if NAV is below threshold
        uint256 leverageRatio = lAmountInWei.wdiv(sAmountInWei);
        uint256 liquidationBoundary = config.liquidationThreshold().wdiv(leverageRatio);
        uint256 nav = _calculateNetAssetValue(user, tokenId);
        require(nav < liquidationBoundary, "LM/ NAV above liquidation threshold");

        // Calculate stable token value to be burned
        uint256 valueToBeBurned = sAmountInWei;
        require(valueToBeBurned > 0, "LM/ Null auction");

        // Calculate residual value to user after liquidation penalty
        uint256 underlyingValueToUser;
        if (nav > config.liquidationPenalty()) {
            underlyingValueToUser = MathUtils.wmul(nav - config.liquidationPenalty(), lAmountInWei);
        } else {
            underlyingValueToUser = 0;
        }

        // Burn leverage tokens and handle interest (executed by Vault for security)
        trancheVault.burnLTokenFromLiquidation(user, tokenId, lAmountInWei);

        // Create Dutch auction
        uint256 auctionId = auctionManager.startAuction(valueToBeBurned, user, tokenId, underlyingValueToUser, kpr);
        emit Barked(user, tokenId, valueToBeBurned, auctionId);
    }



    // ================= Internal Functions =================

    /// @notice Calculates the net asset value (NAV) for a user's leveraged position
    /// @param user Address of the user
    /// @param tokenId Token ID to calculate NAV for
    /// @return nav The net asset value in wei
    /// @custom:error InvalidOraclePrice if oracle price is invalid or zero
    function _calculateNetAssetValue(address user, uint256 tokenId) internal view returns (uint256 nav) {
        IOracleManager oracle = IOracleManager(trancheVault.OMAdrs());
        (uint256 currentPriceInWei, , bool isValid) = oracle.getLatestPriceView();
        require(isValid && currentPriceInWei > 0, "LM/ Invalid Oracle Price");

        ( , , uint256 netNavInWei, , , ) = trancheVault.getLTokenInfo(user, tokenId, currentPriceInWei);
        nav = netNavInWei;
    }

}

