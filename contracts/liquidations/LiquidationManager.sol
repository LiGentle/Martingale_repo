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

contract LiquidationManager is ReentrancyGuard {
    using MathUtils for uint256;

    ProtocolConfig public immutable config;
    LeverageToken public immutable leverageToken;
    ITrancheVault public  trancheVault;  // 核心合约
    IAuctionManager public auctionManager;        // 拍卖模块

    // ================= 用户清算状态 =================
    struct UserLiquidationStatus {
        uint256 balance;               // 余额
        uint256 auctionId;             // 拍卖ID
        uint8 riskLevel;               // 风险等级
        bool isFreezed;                // 是否被冻结 币在清算时被冻结，拍卖完成时解冻。冻结期间无法铸币和销毁
    }
    mapping(address => mapping(uint256 => UserLiquidationStatus)) public userLiquidationStatus;

    // ================= 修饰符 =================
    modifier liquidationEnabled() {
        require(config.liquidationEnabled(), "Liquidation not enabled");
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }


    //================== 定义事件 =================
    event AdminAccessGranted(address indexed user);
    event ParameterChanged(bytes32 indexed parameter, uint256 value);
    event AddressChanged(bytes32 indexed parameter, address addr);
    event RiskLevelUpdated(address indexed user, uint256 indexed tokenId, uint8 riskLevel);

    event TrancheVaultChanged(address indexed oldVault, address indexed newVault);
    event AuctionManagerUpdated(address indexed oldAuctionManager, address indexed newAuctionManager);

    // ================= 构造函数 =================
    constructor(
        address _config,
        address _LTokenAddress
    ){

        require(_config != address(0), "Config cannot be zero address");
        require(_LTokenAddress != address(0), "LeverageToken cannot be zero address");

        config = ProtocolConfig(_config);
        leverageToken = LeverageToken(_LTokenAddress);

    }


    function setTrancheVault(address _newVault) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_newVault != address(0), "Invalid address");
        emit TrancheVaultChanged(address(trancheVault), _newVault);
        trancheVault = ITrancheVault(_newVault);
    }

    function setAuctionManager(address _auctionManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_auctionManager != address(0), "Invalid address");
        emit AuctionManagerUpdated(address(auctionManager), _auctionManager);
        auctionManager = IAuctionManager(_auctionManager);
    }

    // ================= 更新用户清算信息 （铸币时和销毁时均需调用）================
    function updateLiquidationStatus(
        address user, 
        uint256 tokenId,  
        uint256 balance
    ) external onlyRole(config.VAULT_ROLE()) nonReentrant {
        require(address(trancheVault) != address(0), 'Set vault address first');
        userLiquidationStatus[user][tokenId].balance = balance;
    }

    function checkFreezeStatus(address user, uint256 tokenId) public view returns (bool isFreezed){
        isFreezed = userLiquidationStatus[user][tokenId].isFreezed;
    } 

    // ================= 清算功能 =================
    
    /**
     * @dev 触发清算（类似MakerDAO的bark函数）
     * @param user 被清算用户
     * @param tokenId 杠杆币ID
     * @param kpr Keeper地址（接收激励）
     * @return auctionId 创建的拍卖ID
     */
    function bark(
        address user,
        uint256 tokenId,
        address kpr
    ) external liquidationEnabled nonReentrant returns (uint256 auctionId) {
        require(address(auctionManager) != address(0), 'Set auction address first!');
        require(address(trancheVault) != address(0), 'Set Vault address first!');
        require(address(leverageToken) != address(0), 'Set leverageToken address first!');
        require(user != address(0), "Invalid user address");
        require(kpr != address(0), "Invalid keeper address");

        //調用LeverageToken合約中的mapping(uint256 => TokenInfo) public tokens;
        //獲取用戶的SToken和LToken的數量
        (
            , // underlyingAmountInWei
            , // mintPriceInWei
            , // LTVInBps
            uint256 sAmountInWei, 
            uint256 lAmountInWei, 
            , // creationTime
            // isLocked
        ) = leverageToken.getTokenInfo(tokenId);
        require(lAmountInWei > 0, "No tokens to liquidate");
        require(userLiquidationStatus[user][tokenId].isFreezed == false, "The token is under liquidation");
        
        // 检查净值是否低于清算阈值
        uint256 nav = _calculateNetAssetValue(user, tokenId);// 计算净值
        require(nav < config.liquidationThreshold(), "NAV above liquidation threshold");

        // 计算将要销毁的稳定币价值
        uint256 valueToBeBurned = sAmountInWei;
        require(valueToBeBurned > 0, "Null auction");

        // 计算用户残值 
        uint256 underlyingValueToUser; 
        if (nav > config.liquidationPenalty()) {
            underlyingValueToUser = MathUtils.wmul(nav - config.liquidationPenalty(), lAmountInWei); 
        } else {
            underlyingValueToUser = 0;
        }
        
        // 销毁杠杆币，并处理利息 (由 Vault 代理执行，确保权限安全)
        trancheVault.burnLTokenFromLiquidation(user, tokenId, lAmountInWei);

        // 更新用户状态
        userLiquidationStatus[user][tokenId].riskLevel = 4; // 清算中
        userLiquidationStatus[user][tokenId].isFreezed = true;
        userLiquidationStatus[user][tokenId].balance = 0;

        // 创建荷兰式拍卖
        uint256 kprIncentive = MathUtils.wmul(config.liquidationPenalty(), lAmountInWei);
        auctionId = auctionManager.startAuction(valueToBeBurned, kprIncentive, user, tokenId, underlyingValueToUser, kpr);

        // 记录auctionID
        userLiquidationStatus[user][tokenId].auctionId = auctionId;        

        return auctionId;
    }


    /**
     * @dev 计算用户杠杆币的净值
     */
    function _calculateNetAssetValue(address user, uint256 tokenId) internal view returns (uint256 nav) {
        address underlying = trancheVault.underlyingToken();
        IOracleManager oracle = IOracleManager(trancheVault.oracleManager());
        (uint256 currentPriceInWei, , bool isValid) = oracle.getLatestPriceView(underlying);
        require(isValid && currentPriceInWei > 0, "Invalid Oracle Price");

        ( , , uint256 netNavInWei, , , ) = trancheVault.getLTokenInfo(user, tokenId, currentPriceInWei);
        nav = netNavInWei; // 返回净值
    }

    /**
     * @dev 当拍卖结束时，更新清算状态 (由 AuctionManager 调用)
     */
    function _afterAuction(address usr, uint256 tokenID) external onlyRole(config.AUCTION_ROLE()) {
        userLiquidationStatus[usr][tokenID].isFreezed = false; // 解冻
        userLiquidationStatus[usr][tokenID].riskLevel = 0; // 重置riskLevel
        userLiquidationStatus[usr][tokenID].auctionId = 0; // 重置拍卖ID
        // 移除了过时的 custodian.updateDeficit()，资金会计由 Vault 统一处理
    }

    // ================= 风险预览功能 =================

    /**
     * @dev 风险预览 - 持币用户可以调用该函数查看并更新账户内所有token的净值风险等级
     */
    function updateAllTokensRiskLevel(address user) public returns (
        uint256[] memory tokenIds,
        uint256[] memory netValues,
        uint8[] memory riskLevels
    ) {
        require(user != address(0), "Invalid user address");
        require(address(trancheVault) != address(0), "Set Vault address first");
        
        // 从 Vault 获取用户所有token信息
        tokenIds = trancheVault.getUserTokenIds(user);
        
        uint256 tokenCount = tokenIds.length;
        netValues = new uint256[](tokenCount);
        riskLevels = new uint8[](tokenCount);
        
        for (uint256 i = 0; i < tokenCount; i++) {
            uint256 tokenId = tokenIds[i];
            uint256 balance = leverageToken.balanceOf(user, tokenId);
            
            if (balance > 0) {
                // 获取净值
                uint256 netNavInWei = _calculateNetAssetValue(user, tokenId);
                netValues[i] = netNavInWei;
                
                // 计算风险等级并更新
                riskLevels[i] = _calculateRiskLevel(netNavInWei);
                userLiquidationStatus[user][tokenId].riskLevel = riskLevels[i];
            } else {
                netValues[i] = 0;
                riskLevels[i] = 0;
            }
        }
        
        return (tokenIds, netValues, riskLevels);
    }

    function updateSingleTokensRiskLevel(address user, uint256 tokenId) public returns (
        uint256 netValue,
        uint8 riskLevel
    ) {
        require(user != address(0), "Invalid user address");
        require(address(trancheVault) != address(0), "Set Vault address first");
        
        uint256 balance = leverageToken.balanceOf(user, tokenId);
        require(balance > 0, "User does not hold this token");
        
        netValue = _calculateNetAssetValue(user, tokenId);
        riskLevel = _calculateRiskLevel(netValue);
        
        userLiquidationStatus[user][tokenId].riskLevel = riskLevel;
    }

    /**
     * @dev 计算风险等级
     * @param netValue 净值（18位精度）
     */
    function _calculateRiskLevel(uint256 netValue) internal view returns (uint8 riskLevel) {
        if (netValue <= config.liquidationThreshold()) {
            riskLevel = 4;
        } else if (netValue <= config.adjustmentThreshold()) {
            uint256 range = config.adjustmentThreshold() - config.liquidationThreshold();
            uint256 position = netValue - config.liquidationThreshold();
            
            uint256 segment = range / 3;
            
            if (position <= segment) {
                riskLevel = 3; 
            } else if (position <= segment * 2) {
                riskLevel = 2; 
            } else {
                riskLevel = 1; 
            }
        } else {
            riskLevel = 0;
        }
    }
}

