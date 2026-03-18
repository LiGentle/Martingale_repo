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

    // --- 数据 ---
    ProtocolConfig public immutable config;
    StableToken public immutable stableToken;
    
    ITrancheVault public trancheVault;
    LiquidationManager public liquidationManager;

    uint256 public totalAuctions = 0;
    
    // 循环优化 - 使用映射跟踪活跃拍卖
    mapping(uint256 => bool) public isActiveAuction;
    uint256 public activeAuctionCount;


    struct Auction {
        uint256 valueToBeBurned;      // 需要銷毀的穩定幣的金額 [1e18]
        address originalOwner;        // 被清算的杠杆币所有者
        uint256 tokenId;              // tokenID
        uint96  startTime;            // 拍卖开始时间
        uint256 startingPrice;        // 起始价格 [1e18]
        uint256 currentPrice;         // 当前价格 [1e18]
    }
    mapping(uint256 => Auction) public auctions;

    // --- 事件 ---
    event TrancheVaultUpdated(address indexed oldVault, address indexed newVault);
    event LiquidationManagerUpdated(address indexed oldManager, address indexed newManager);

    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 valueToBeBurned,
        uint256 startingPrice,
        address originalOwner,
        uint256 indexed tokenId,
        address indexed triggerer,
        uint256 rewardValue
    );
    event PurchaseMade(
        uint256 indexed auctionId,
        uint256 currentPrice,
        uint256 purchaseSlice,
        uint256 remainingValueToBeBurned,
        address indexed kpr,
        address indexed originalOwner
    );
    event AuctionReset(
        uint256 indexed auctionId,
        uint256 valueToBeBurned,
        uint256 newStartingPrice,
        address originalOwner,
        uint256 indexed tokenId,
        address indexed triggerer,
        uint256 rewardValue
    );
    event AuctionRemoved(uint256 auctionId);
    event AuctionCancelled(uint256 auctionId);

    // --- 修饰符 ---
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }


    modifier checkCircuitBreaker(uint256 level) {
        require(config.circuitBreaker() < level, 'CircuitBreaker error!');
        _;
    }

    // --- 初始化 ---
    constructor(
        address _config,
        address _STokenAddress
    ) {      
        require(_config != address(0), "Config cannot be zero address");
        require(_STokenAddress != address(0), "StableToken address cannot be 0");
        config = ProtocolConfig(_config);
        stableToken = StableToken(_STokenAddress);  
    }

    // --- 管理功能 ---
    function setTrancheVault(address _trancheVault) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        emit TrancheVaultUpdated(address(trancheVault), _trancheVault);
        trancheVault = ITrancheVault(_trancheVault);
    }
    
    function setLiquidationManager(address _liquidationManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        emit LiquidationManagerUpdated(address(liquidationManager), _liquidationManager);
        liquidationManager = LiquidationManager(_liquidationManager);
    }
    

    // --- 内部获取预言机价格 ---
    function _getLatestPrice() internal view returns (uint256) {
        require(address(trancheVault) != address(0), "Vault not set");
        IOracleManager oracle = IOracleManager(trancheVault.OMAdrs());
        (uint256 currentPrice, , bool isValid) = oracle.getLatestPriceView();
        require(currentPrice > 0 && isValid, "Invalid oracle price!");
        return currentPrice;
    }

    // --- 拍卖功能 ---

    // 开始拍卖
    function startAuction(
        uint256 valueToBeBurned,  // 需被销毁的稳定币价值
        address originalOwner,    // 被清算用户地址
        uint256 tokenId,          // tokenID
        uint256 underlyingValueToUser, // 返还给用户的残值
        address triggerer         // 将接收激励的地址
    ) external onlyRole(config.LIQUIDATION_ROLE()) nonReentrant checkCircuitBreaker(1) returns (uint256 auctionId) {
        
        auctionId = ++totalAuctions;
        isActiveAuction[auctionId] = true;
        activeAuctionCount++;

        uint256 currentPrice = _getLatestPrice();
        
        (
            uint256 priceMultiplier,
            , // resetTime
            , // priceDropThreshold
            uint256 percentageReward,
            uint256 fixedReward,
            uint256 minAuctionAmount
        ) = config.auctionParams();

        uint256 startingPrice = currentPrice.wmul(priceMultiplier);

        uint256 rewardValue;
        if (fixedReward > 0 || percentageReward > 0) {
            if (valueToBeBurned.wdiv(currentPrice) >= minAuctionAmount) {
                rewardValue = fixedReward + (valueToBeBurned - minAuctionAmount.wmul(currentPrice)).wmul(percentageReward);
            } else {
                rewardValue = fixedReward;
            }
        }

        auctions[auctionId].startingPrice = startingPrice;
        auctions[auctionId].valueToBeBurned = valueToBeBurned;
        auctions[auctionId].originalOwner = originalOwner;
        auctions[auctionId].tokenId = tokenId;
        auctions[auctionId].startTime = uint96(block.timestamp);
        
        trancheVault.transferUnderlying(originalOwner, underlyingValueToUser.wdiv(currentPrice));
        trancheVault.transferUnderlying(triggerer, rewardValue.wdiv(currentPrice));
        
        emit AuctionStarted(auctionId, valueToBeBurned, startingPrice, originalOwner, tokenId, triggerer, rewardValue);
    }

    // 重置拍卖
    function resetAuction(
        uint256 auctionId,  // 要重置的拍卖ID
        address triggerer   // 将接收激励的地址
    ) external nonReentrant checkCircuitBreaker(2) {
        address originalOwner = auctions[auctionId].originalOwner;
        uint96 startTime = auctions[auctionId].startTime;
        uint256 startingPrice = auctions[auctionId].startingPrice;
        require(originalOwner != address(0), "Invalid Original Owner!");

        (bool needsReset,) = checkAuctionStatus(startTime, startingPrice);
        require(needsReset, "Auction is not ready to be reset!");

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

        startingPrice = currentPrice.wmul(priceMultiplier);
        auctions[auctionId].startingPrice = startingPrice;

        uint256 rewardValue;
        if (fixedReward > 0 || percentageReward > 0) {
            if (valueToBeBurned.wdiv(currentPrice) >= minAuctionAmount) {
                rewardValue = fixedReward + (valueToBeBurned - minAuctionAmount.wmul(currentPrice)).wmul(percentageReward);
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

    // 购买底层资产
    function bid(
        uint256 auctionId,           // 拍卖ID
        uint256 maxPurchaseAmount,   // 购买underlying数量的上限 [Wei]
        uint256 maxAcceptablePrice,  // 最高可接受价格 [Wei]
        address receiver           // underlying接收者和外部调用地址
    ) external nonReentrant checkCircuitBreaker(3) {
        require(address(stableToken) != address(0), 'stableToken address is not set');
        ensureApproval(maxPurchaseAmount.wmul(maxAcceptablePrice));
        
        address originalOwner = auctions[auctionId].originalOwner;
        require(originalOwner != address(0), "Auction not ready");

        uint96 startTime = auctions[auctionId].startTime;
        uint256 currentPrice;
        {
            bool needsReset;
            (needsReset, currentPrice) = checkAuctionStatus(startTime, auctions[auctionId].startingPrice);
            require(!needsReset, "Auction needs to be reset");
        }

        require(maxAcceptablePrice >= currentPrice, "Current price is above acceptable price");

        (,,,,, uint256 minAuctionAmount) = config.auctionParams();
        require(maxPurchaseAmount >= minAuctionAmount, 'Purchase amount should be no less than the minimum purchase limit');

        uint256 valueToBeBurned = auctions[auctionId].valueToBeBurned;
        uint256 paymentAmount;
        uint256 purchaseSlice = maxPurchaseAmount;

        paymentAmount = purchaseSlice.wmul(currentPrice);

        if (paymentAmount > valueToBeBurned) {
            paymentAmount = valueToBeBurned;
            purchaseSlice = paymentAmount.wdiv(currentPrice);
        } else {
            uint256 residualAmount = (valueToBeBurned - paymentAmount).wdiv(currentPrice);
            require(residualAmount > minAuctionAmount, 'Residual value is too small, please increase purchase amount');
        }

        auctions[auctionId].valueToBeBurned = valueToBeBurned - paymentAmount;

        emit PurchaseMade(auctionId, currentPrice, purchaseSlice, auctions[auctionId].valueToBeBurned, receiver, originalOwner);

        if (auctions[auctionId].valueToBeBurned == 0) {
            liquidationManager._afterAuction(originalOwner, auctions[auctionId].tokenId);
            removeAuction(auctionId);
        }

        trancheVault.transferUnderlying(receiver, purchaseSlice);
        
        trancheVault.burnSToken(msg.sender, paymentAmount);
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
        require(isActiveAuction[auctionId], 'The auction is not active');
        address originalOwner = auctions[auctionId].originalOwner;
        uint96 startTime = auctions[auctionId].startTime;

        bool done;
        (done, currentPrice) = checkAuctionStatus(startTime, auctions[auctionId].startingPrice);

        needsReset = originalOwner != address(0) && done;
        valueToBeBurned = auctions[auctionId].valueToBeBurned;
    }

    function checkAuctionStatus(uint96 startTime, uint256 startingPrice) internal view returns (bool needsReset, uint256 currentPrice) {        
        (,uint256 resetTime,uint256 priceDropThreshold,,,) = config.auctionParams();
        uint256 priceLowerBound = startingPrice.wmul(priceDropThreshold);
        require(priceLowerBound < startingPrice, "AM/ invalid priceDropThreshold");
        uint256 timeElapsed = block.timestamp - startTime;
        needsReset = timeElapsed >= resetTime;
        if (needsReset){
            currentPrice = priceLowerBound;
        } else {
            currentPrice = (startingPrice - priceLowerBound).wmul((resetTime - timeElapsed).wdiv(resetTime)) + priceLowerBound;
        }
    }

    // 取消拍卖（紧急情况或治理操作）
    function cancelAuction(uint256 auctionId) external onlyRole(config.DEFAULT_ADMIN_ROLE()) nonReentrant {
        require(auctions[auctionId].originalOwner != address(0), "Auction not started");
        removeAuction(auctionId);
        emit AuctionCancelled(auctionId);
    }
}