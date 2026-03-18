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

    ProtocolConfig public immutable config;
    LeverageToken public immutable leverageToken;
    ITrancheVault public  trancheVault;  // 核心合约
    IAuctionManager public auctionManager;        // 拍卖模块

    // ================= 用户清算状态 =================
    struct UserLiquidationStatus {
        bool isFreezed;                // 是否被冻结 币在清算时被冻结，拍卖完成时解冻。冻结期间无法铸币和销毁
        bool isLocked;                  // 是否被锁定 （锁定后的L无法被清算）
    }
    mapping(address => mapping(uint256 => UserLiquidationStatus)) public userLiquidationStatus;

    // ================= 修饰符 =================
    modifier liquidationEnabled() {
        require(config.liquidationEnabled(), "LM/ Liquidation not enabled");
        _;
    }
    
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "LM/ Caller missing required role");
        _;
    }


    //================== 定义事件 =================
    event TrancheVaultChanged(address indexed oldVault, address indexed newVault);
    event AuctionManagerUpdated(address indexed oldAuctionManager, address indexed newAuctionManager);
    event Barked(address user, uint256 tokenId, uint256 valueToBeBurned, uint256 auctionId);
    event Protect(address user, uint256 tokenId);
    event LiftProtection(address user, uint256 tokenId);
    // ================= 构造函数 =================
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

    // ================= 检查清算状态（销毁时需调用）================
    function checkFreezeStatus(address user, uint256 tokenId) public view returns (bool isFreezed){
        isFreezed = userLiquidationStatus[user][tokenId].isFreezed;
    } 

    function checkLockStatus (address user, uint256 tokenId) public view returns (bool isLocked){
        isLocked = userLiquidationStatus[user][tokenId].isLocked;
    } 

   // ================= 清算保护 =================
    
    /**
     * @dev 存入S锁定L，对L开启清算保护
     * @param tokenId 杠杆币ID
     */

    function protectL( uint256 tokenId) public nonReentrant liquidationEnabled()
    {
        address user = msg.sender;
        uint256 balance = leverageToken.balanceOfInWei(user, tokenId);
        require(balance > 0, "LM/ No token to protect");
        require(userLiquidationStatus[user][tokenId].isFreezed == false, "LM/ The token is under liquidation");
        require(userLiquidationStatus[user][tokenId].isLocked == false, "LM/ The token is already under protection");
        (
            , // underlyingAmountInWei
            , // mintPriceInWei
            , // LTVInBps
            uint256 sAmountInWei, 
            uint256 lAmountInWei, 
            , // creationTime
            // isLocked
        ) = leverageToken.getTokenInfo(tokenId);
        // 检查净值是否低于清算边界
        uint256 leverageRatio = lAmountInWei.wdiv(sAmountInWei);
        uint256 liquidationBoundary = config.liquidationThreshold().wdiv(leverageRatio);
        uint256 nav = _calculateNetAssetValue(user, tokenId);
        require(nav > liquidationBoundary, "LM/ Tokens with NAV below liquidation boundary cannot be protected");

        // 冻结稳定币
        trancheVault.freezeStable(user, sAmountInWei);
        userLiquidationStatus[user][tokenId].isLocked = true;
        emit Protect(user, tokenId);
    }

    function liftProtection(uint256 tokenId) public nonReentrant liquidationEnabled()
    {
        address user = msg.sender;
        uint256 balance = leverageToken.balanceOfInWei(user, tokenId);
        require(balance > 0, "LM/ No tokens");
        require(userLiquidationStatus[user][tokenId].isLocked == true, "LM/ The tokens are not under protection");
        (
            , // underlyingAmountInWei
            , // mintPriceInWei
            , // LTVInBps
            uint256 sAmountInWei, 
            uint256 lAmountInWei, 
            , // creationTime
            // isLocked
        ) = leverageToken.getTokenInfo(tokenId);
        // 检查净值是否低于清算边界
        uint256 leverageRatio = lAmountInWei.wdiv(sAmountInWei);
        uint256 liquidationBoundary = config.liquidationThreshold().wdiv(leverageRatio);
        uint256 nav = _calculateNetAssetValue(user, tokenId);
        require(nav > liquidationBoundary, "LM/ Tokens with NAV below liquidation boundary cannot be lifted from protection");

        userLiquidationStatus[user][tokenId].isLocked = false;
        trancheVault.unfreezeStable(user, sAmountInWei);
        emit LiftProtection(user, tokenId);
    }

    // ================= 清算功能 =================
    
    /**
     * @dev 触发清算（类似MakerDAO的bark函数）
     * @param user 被清算用户
     * @param tokenId 杠杆币ID
     * @param kpr Keeper地址（接收激励）
     */
    function bark(
        address user,
        uint256 tokenId,
        address kpr
    ) external liquidationEnabled nonReentrant {
        require(address(auctionManager) != address(0), 'LM/ Set auction address first!');
        require(address(trancheVault) != address(0), 'LM/ Set Vault address first!');
        require(address(leverageToken) != address(0), 'LM/ Set leverageToken address first!');
        require(user != address(0), "LM/ Invalid user address");
        require(kpr != address(0), "LM/ Invalid keeper address");
        require(userLiquidationStatus[user][tokenId].isFreezed == false, "LM/ The token is under liquidation");
        require(userLiquidationStatus[user][tokenId].isLocked== false, "LM/ The token is under protection");
        uint256 balance = leverageToken.balanceOf(user, tokenId);
        require(balance > 0, "LM/ No tokens");

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
        uint256 leverageRatio = lAmountInWei.wdiv(sAmountInWei);
        uint256 liquidationBoundary = config.liquidationThreshold().wdiv(leverageRatio);
        // 检查净值是否低于清算阈值
        uint256 nav = _calculateNetAssetValue(user, tokenId);// 计算净值
        require(nav < liquidationBoundary, "LM/ NAV above liquidation threshold");

        // 计算将要销毁的稳定币价值
        uint256 valueToBeBurned = sAmountInWei;
        require(valueToBeBurned > 0, "LM/ Null auction");

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
        userLiquidationStatus[user][tokenId].isFreezed = true;

        // 创建荷兰式拍卖
        uint256 auctionId =  auctionManager.startAuction(valueToBeBurned, user, tokenId, underlyingValueToUser, kpr);
        emit Barked(user, tokenId, valueToBeBurned, auctionId);
    }


    /**
     * @dev 计算用户杠杆币的净值
     */
    function _calculateNetAssetValue(address user, uint256 tokenId) internal view returns (uint256 nav) {
        IOracleManager oracle = IOracleManager(trancheVault.OMAdrs());
        (uint256 currentPriceInWei, , bool isValid) = oracle.getLatestPriceView();
        require(isValid && currentPriceInWei > 0, "LM/ Invalid Oracle Price");

        ( , , uint256 netNavInWei, , , ) = trancheVault.getLTokenInfo(user, tokenId, currentPriceInWei);
        nav = netNavInWei; // 返回净值
    }

    /**
     * @dev 当拍卖结束时，更新清算状态 (由 AuctionManager 调用)
     */
    function _afterAuction(address usr, uint256 tokenID) external onlyRole(config.AUCTION_ROLE()) {
        userLiquidationStatus[usr][tokenID].isFreezed = false; // 解冻
    }
}
