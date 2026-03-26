// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../tokens/StableToken.sol";
import "./LiquidationManager.sol";
import "../config/ProtocolConfig.sol";
import "../interfaces/ITrancheVault.sol";
import "../interfaces/IOracleManager.sol";
import "../libraries/MathUtils.sol";
import "../interfaces/IAuctionManager.sol";

contract AuctionManager is ReentrancyGuard, IAuctionManager {
    using MathUtils for uint256;

    // ================= Constants =================

    /// @notice Circuit breaker levels
    uint256 private constant CIRCUIT_BREAKER_START = 1;
    uint256 private constant CIRCUIT_BREAKER_RESET = 2;
    uint256 private constant CIRCUIT_BREAKER_BID = 3;

    // ================= State Variables =================

    /// @notice Protocol configuration contract (immutable)
    ProtocolConfig public immutable config;

    /// @notice Stable token contract (immutable)
    StableToken public immutable stableToken;

    /// @notice Tranche vault interface
    ITrancheVault public trancheVault;

    /// @notice Liquidation manager interface
    LiquidationManager public liquidationManager;

    /// @notice Total number of auctions created
    uint256 public totalAuctions;

    /// @notice Mapping to track active auctions
    mapping(uint256 => bool) public isActiveAuction;

    /// @notice Count of currently active auctions
    uint256 public activeAuctionCount;

    // ================= Data Structures =================

    /// @notice Auction structure containing all auction data
    /// @param valueToBeBurned Amount of stable tokens to be burned [1e18]
    /// @param originalOwner Address of the liquidated leveraged token owner
    /// @param tokenId Token ID being liquidated
    /// @param startTime Auction start timestamp
    /// @param startingPrice Starting auction price [1e18]
    /// @param currentPrice Current auction price [1e18]
    struct Auction {
        uint256 valueToBeBurned;
        address originalOwner;
        uint256 tokenId;
        uint256 startTime;
        uint256 startingPrice;
        uint256 currentPrice;
    }

    /// @notice Mapping of auction ID to auction data
    mapping(uint256 => Auction) public auctions;

    // ================= Events =================

    /// @notice Emitted when tranche vault address is updated
    /// @param oldVault Previous vault address
    /// @param newVault New vault address
    event TrancheVaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice Emitted when liquidation manager address is updated
    /// @param oldManager Previous liquidation manager address
    /// @param newManager New liquidation manager address
    event LiquidationManagerUpdated(address indexed oldManager, address indexed newManager);

    /// @notice Emitted when a new auction is started
    /// @param auctionId Auction ID
    /// @param valueToBeBurned Amount of stable tokens to be burned
    /// @param startingPrice Starting auction price
    /// @param originalOwner Address of the liquidated user
    /// @param tokenId Token ID being liquidated
    /// @param triggerer Address that triggered the liquidation
    /// @param rewardValue Reward value for the triggerer
    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 valueToBeBurned,
        uint256 startingPrice,
        address indexed originalOwner,
        uint256 indexed tokenId,
        address triggerer,
        uint256 rewardValue
    );

    /// @notice Emitted when a purchase is made on an auction
    /// @param auctionId Auction ID
    /// @param currentPrice Current auction price
    /// @param purchaseSlice Amount of underlying purchased
    /// @param remainingValueToBeBurned Remaining value to be burned
    /// @param kpr Address of the keeper making the purchase
    /// @param originalOwner Address of the original owner
    event PurchaseMade(
        uint256 indexed auctionId,
        uint256 currentPrice,
        uint256 purchaseSlice,
        uint256 remainingValueToBeBurned,
        address indexed kpr,
        address indexed originalOwner
    );

    /// @notice Emitted when an auction is reset
    /// @param auctionId Auction ID
    /// @param valueToBeBurned Amount of stable tokens to be burned
    /// @param newStartingPrice New starting price
    /// @param originalOwner Address of the original owner
    /// @param tokenId Token ID
    /// @param triggerer Address that triggered the reset
    /// @param rewardValue Reward value for the triggerer
    event AuctionReset(
        uint256 indexed auctionId,
        uint256 valueToBeBurned,
        uint256 newStartingPrice,
        address indexed originalOwner,
        uint256 tokenId,
        address triggerer,
        uint256 rewardValue
    );

    /// @notice Emitted when an auction is removed
    /// @param auctionId Auction ID
    event AuctionRemoved(uint256 indexed auctionId);

    /// @notice Emitted when an auction is cancelled
    /// @param auctionId Auction ID
    event AuctionCancelled(uint256 indexed auctionId);

    // ================= Modifiers =================

    /// @notice Modifier to restrict function execution to specific roles
    /// @param role The role identifier from ProtocolConfig
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "AM/ Caller missing required role");
        _;
    }

    /// @notice Modifier to check circuit breaker level
    /// @param level Circuit breaker level to check against
    modifier checkCircuitBreaker(uint256 level) {
        require(config.circuitBreaker() < level, "AM/ Circuit breaker triggered");
        _;
    }

    // ================= Constructor =================

    /// @notice Constructor to initialize the AuctionManager contract
    /// @param _config Address of the ProtocolConfig contract
    /// @param _STokenAddress Address of the StableToken contract
    /// @custom:error ZeroAddressConfig if _config is zero address
    /// @custom:error ZeroAddressStableToken if _STokenAddress is zero address
    constructor(
        address _config,
        address _STokenAddress
    ) {
        require(_config != address(0), "AM/ Config cannot be zero address");
        require(_STokenAddress != address(0), "AM/ StableToken address cannot be 0");
        config = ProtocolConfig(_config);
        stableToken = StableToken(_STokenAddress);
    }

    // ================= Configuration Management =================

    /// @notice Sets the tranche vault address
    /// @param _trancheVault Address of the new tranche vault
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    /// @custom:error ZeroAddress if _trancheVault is zero address
    function setTrancheVault(address _trancheVault) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_trancheVault != address(0), "AM/ Vault cannot be zero address");
        emit TrancheVaultUpdated(address(trancheVault), _trancheVault);
        trancheVault = ITrancheVault(_trancheVault);
    }

    /// @notice Sets the liquidation manager address
    /// @param _liquidationManager Address of the new liquidation manager
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    /// @custom:error ZeroAddress if _liquidationManager is zero address
    function setLiquidationManager(address _liquidationManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_liquidationManager != address(0), "AM/ Liquidation manager cannot be zero address");
        emit LiquidationManagerUpdated(address(liquidationManager), _liquidationManager);
        liquidationManager = LiquidationManager(_liquidationManager);
    }

    // ================= Internal Functions =================

    /// @notice Gets the latest price from oracle
    /// @return currentPrice Latest no delay price in wei
    /// @custom:error VaultNotSet if tranche vault is not configured
    function _getLatestPrice() internal view returns(uint256) {
        require(address(trancheVault) != address(0), "AM/ Vault not set");
        IOracleManager oracle = IOracleManager(trancheVault.OMAdrs());
        uint256 currentPrice = oracle.getNoDelayPrice();
        return currentPrice;
    }

    // ================= Auction Management =================

    /// @notice Starts a new Dutch auction for liquidated collateral
    /// @param valueToBeBurned Amount of stable tokens to be burned
    /// @param originalOwner Address of the liquidated user
    /// @param tokenId Token ID being liquidated
    /// @param underlyingValueToUser Residual value to return to user
    /// @param triggerer Address receiving the keeper reward
    /// @return auctionId The ID of the created auction
    /// @custom:error ZeroAddressOwner if originalOwner is zero address
    /// @custom:error ZeroAddressTriggerer if triggerer is zero address
    function startAuction(
        uint256 valueToBeBurned,
        address originalOwner,
        uint256 tokenId,
        uint256 underlyingValueToUser,
        address triggerer
    ) external onlyRole(config.LIQUIDATION_ROLE()) nonReentrant checkCircuitBreaker(CIRCUIT_BREAKER_START) returns (uint256 auctionId) {
        require(originalOwner != address(0), "AM/ Original owner cannot be zero address");
        require(triggerer != address(0), "AM/ Triggerer cannot be zero address");

        auctionId = ++totalAuctions;
        isActiveAuction[auctionId] = true;
        activeAuctionCount++;

        uint256 currentPrice = _getLatestPrice();

        (
            uint256 priceMultiplier,
            ,
            ,
            uint256 percentageReward,
            uint256 fixedReward,
            uint256 minAuctionAmount
        ) = config.auctionParams();

        uint256 startingPrice = currentPrice.bmul(priceMultiplier);

        uint256 rewardValue;
        if (fixedReward > 0 || percentageReward > 0) {
            if (valueToBeBurned.wdiv(currentPrice) >= minAuctionAmount) {
                rewardValue = fixedReward + (valueToBeBurned - minAuctionAmount.wmul(currentPrice)).bmul(percentageReward);
            } else {
                rewardValue = fixedReward;
            }
        }

        auctions[auctionId].startingPrice = startingPrice;
        auctions[auctionId].valueToBeBurned = valueToBeBurned;
        auctions[auctionId].originalOwner = originalOwner;
        auctions[auctionId].tokenId = tokenId;
        auctions[auctionId].startTime = block.timestamp;

        trancheVault.transferUnderlying(originalOwner, underlyingValueToUser.wdiv(currentPrice));
        trancheVault.transferUnderlying(triggerer, rewardValue.wdiv(currentPrice));

        emit AuctionStarted(auctionId, valueToBeBurned, startingPrice, originalOwner, tokenId, triggerer, rewardValue);
    }

    /// @notice Resets an auction that hasn't been completed
    /// @param auctionId Auction ID to reset
    /// @param triggerer Address receiving the keeper reward
    /// @dev Only callable when auction needs reset based on time and price conditions
    /// @custom:error AuctionNotReady if auction doesn't need reset
    /// @custom:error ZeroAddressTriggerer if triggerer is zero address
    function resetAuction(
        uint256 auctionId,
        address triggerer
    ) external nonReentrant checkCircuitBreaker(CIRCUIT_BREAKER_RESET) {
        require(triggerer != address(0), "AM/ Triggerer cannot be zero address");
        address originalOwner = auctions[auctionId].originalOwner;
        uint256 startTime = auctions[auctionId].startTime;
        uint256 startingPrice = auctions[auctionId].startingPrice;
        require(originalOwner != address(0), "AM/ Invalid original owner");

        (bool needsReset,) = checkAuctionStatus(startTime, startingPrice);
        require(needsReset, "AM/ Auction is not ready to be reset");

        uint256 valueToBeBurned = auctions[auctionId].valueToBeBurned;
        auctions[auctionId].startTime = uint96(block.timestamp);

        uint256 currentPrice = _getLatestPrice();
        
        (
            uint256 priceMultiplier,
            , // resetTime
            , // priceDropThreshold
            uint256 percentageReward,
            uint256 fixedReward,
            uint256 minAuctionAmount
        ) = config.auctionParams();

        startingPrice = currentPrice.bmul(priceMultiplier);
        auctions[auctionId].startingPrice = startingPrice;

        uint256 rewardValue;
        if (fixedReward > 0 || percentageReward > 0) {
            if (valueToBeBurned.wdiv(currentPrice) >= minAuctionAmount) {
                rewardValue = fixedReward + (valueToBeBurned - minAuctionAmount.wmul(currentPrice)).bmul(percentageReward);
            } else {
                rewardValue = fixedReward;
            }
        }

        trancheVault.transferUnderlying(triggerer, rewardValue.wdiv(currentPrice));

        emit AuctionReset(auctionId, valueToBeBurned, startingPrice, originalOwner, auctions[auctionId].tokenId, triggerer, rewardValue);
    }

    function ensureApproval(uint256 amount) internal view {
        uint256 currentAllowance = stableToken.allowance(msg.sender, address(trancheVault));
        if (currentAllowance < amount) {
            revert("Insufficient approval. Please approve TrancheVault to spend your stable tokens");
        }
    }

    /// @notice Bids on an active auction to purchase underlying assets
    /// @param auctionId Auction ID to bid on
    /// @param maxPurchaseAmount Maximum amount of underlying to purchase [Wei]
    /// @param maxAcceptablePrice Maximum acceptable price [Wei]
    /// @param receiver Address to receive the purchased underlying assets
    /// @custom:error InsufficientApproval if user hasn't approved enough stable tokens
    /// @custom:error AuctionNotReady if auction doesn't exist or isn't ready
    /// @custom:error AuctionNeedsReset if auction requires reset
    /// @custom:error PriceTooHigh if current price exceeds acceptable price
    /// @custom:error InsufficientPurchaseAmount if purchase amount is below minimum
    function bid(
        uint256 auctionId,
        uint256 maxPurchaseAmount,
        uint256 maxAcceptablePrice,
        address receiver
    ) external nonReentrant checkCircuitBreaker(CIRCUIT_BREAKER_BID) {
        require(address(stableToken) != address(0), 'AM/ stableToken address is not set');
        ensureApproval(maxPurchaseAmount.wmul(maxAcceptablePrice));
        
        address originalOwner = auctions[auctionId].originalOwner;
        require(originalOwner != address(0), "AM/ Auction not ready");

        uint256 startTime = auctions[auctionId].startTime;
        uint256 currentPrice;
        bool needsReset;
        (needsReset, currentPrice) = checkAuctionStatus(startTime, auctions[auctionId].startingPrice);
        require(!needsReset, "AM/ Auction needs to be reset");

        require(maxAcceptablePrice >= currentPrice, "AM/ Current price is above acceptable price");

        (,,,,, uint256 minAuctionAmount) = config.auctionParams();
        require(maxPurchaseAmount >= minAuctionAmount, "AM/ Purchase amount below minimum");

        uint256 valueToBeBurned = auctions[auctionId].valueToBeBurned;
        uint256 paymentAmount;
        uint256 purchaseSlice = maxPurchaseAmount;

        paymentAmount = purchaseSlice.wmul(currentPrice);

        if (paymentAmount > valueToBeBurned) {
            paymentAmount = valueToBeBurned;
            purchaseSlice = paymentAmount.wdiv(currentPrice);
        } else {
            uint256 residualAmount = (valueToBeBurned - paymentAmount).wdiv(currentPrice);
            require(residualAmount > minAuctionAmount, "AM/ Residual value too small");
        }

        auctions[auctionId].valueToBeBurned = valueToBeBurned - paymentAmount;

        emit PurchaseMade(auctionId, currentPrice, purchaseSlice, auctions[auctionId].valueToBeBurned, receiver, originalOwner);

        if (auctions[auctionId].valueToBeBurned == 0) {
            removeAuction(auctionId);
        }
        trancheVault.burnSToken(msg.sender, paymentAmount);
        trancheVault.transferUnderlying(receiver, purchaseSlice);    
    }

    function removeAuction(uint256 auctionId) internal {
        isActiveAuction[auctionId] = false;
        activeAuctionCount--;
        delete auctions[auctionId];
        emit AuctionRemoved(auctionId);
    }

    function getActiveAuctionCount() external view returns (uint256) {
        return activeAuctionCount;
    }

    function auctionIsActive(uint256 auctionId) external view returns (bool) {
        return isActiveAuction[auctionId];
    }

    function getAuctionStatus(uint256 auctionId) external view returns (bool needsReset, uint256 currentPrice, uint256 valueToBeBurned) {
        require(isActiveAuction[auctionId], "AM/ Auction is not active");
        address originalOwner = auctions[auctionId].originalOwner;
        uint256 startTime = auctions[auctionId].startTime;

        bool done;
        (done, currentPrice) = checkAuctionStatus(startTime, auctions[auctionId].startingPrice);

        needsReset = originalOwner != address(0) && done;
        valueToBeBurned = auctions[auctionId].valueToBeBurned;
    }

    function checkAuctionStatus(uint256 startTime, uint256 startingPrice) internal view returns (bool needsReset, uint256 currentPrice) {        
        (,uint256 resetTime,uint256 priceDropThreshold,,,) = config.auctionParams();
        uint256 priceLowerBound = startingPrice.bmul(priceDropThreshold);
        require(priceLowerBound < startingPrice, "AM/ invalid priceDropThreshold");
        uint256 timeElapsed = block.timestamp - startTime;
        needsReset = timeElapsed >= resetTime;
        if (needsReset){
            currentPrice = priceLowerBound;
        } else {
            currentPrice = (startingPrice - priceLowerBound).wmul((resetTime - timeElapsed).wdiv(resetTime)) + priceLowerBound;
        }
    }

    /// @notice Cancels an active auction (emergency or governance action)
    /// @param auctionId Auction ID to cancel
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    /// @custom:error AuctionNotStarted if auction hasn't been started
    function cancelAuction(uint256 auctionId) external onlyRole(config.DEFAULT_ADMIN_ROLE()) nonReentrant {
        require(auctions[auctionId].originalOwner != address(0), "AM/ Auction not started");
        removeAuction(auctionId);
        emit AuctionCancelled(auctionId);
    }
}
