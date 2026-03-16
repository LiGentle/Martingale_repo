// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/LeverageToken.sol";
import "../config/ProtocolConfig.sol";
import "../libraries/DataTypes.sol";
import "../interfaces/ITrancheVault.sol";
import "../interfaces/IStableSwapAMM.sol";



/**
 * @title Constant InterestManager
 * @dev 动态利率的利息管理合约
 * @notice 使用动态年化利率，包含 Base Rate, Utilization Rate (基于 AMM), Collateral Risk Premium
 */
contract InterestManager is ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ================= 核心合约引用 =================
    
    ProtocolConfig public immutable config;
    IERC20 public immutable underlyingToken;               // 标的资产 (LTC)
    LeverageToken public immutable leverageToken;                    // 杠杆代币合约
    ITrancheVault public trancheVault;                     // 核心合约
    IStableSwapAMM public ammPool;                         // AMM 池合约地址

    
    // ================= 利息统计 =================
    
    uint256 public totalInterestAccrued;                   // 累计产生的利息
    uint256 public totalInterestCollected;                 // 累计收取的利息
    uint256 public totalInterestWithdrawn;                 // 累计提取的利息
    uint256 public totalActivePositions;                   // 活跃持仓数量
    uint256 public totalLeverageAmount;                    // 总杠杆金额
    
    // ================= 用户持仓数据 =================
    
    struct UserInterestData {
        uint256 sAmountInWei;          // 稳定代币数量, 借出的 stable  stable 代币数量
        uint256 lAmountInWei;          // 杠杆代币数量
        uint256 timestamp;             // 最后更新时间
        uint256 accruedInterest;       // 累计未收取利息，in USD value
        bool active;                   // 是否活跃
    }
    
    mapping(address => mapping(uint256 => UserInterestData)) public userInterestData;
    
    // ================= 事件定义 =================
    
    event ContractInitialized(address indexed leverageToken, address indexed trancheVault);
    event PositionOpened(address indexed user, uint256 indexed tokenId, uint256 sAmountInWei, uint256 lAmountInWei, uint256 timestamp);
    event PositionIncreased(address indexed user, uint256 indexed tokenId, uint256 sAmountInWei, uint256 lAmountInWei, uint256 totalSAmountInWei, uint256 totalLAmountInWei);
    event PositionClosed(address indexed user, uint256 indexed tokenId, uint256 sAmountInWei, uint256 lAmountInWei);
    event InterestAccrued(address indexed user, uint256 indexed tokenId, uint256 interestAmount);
    event InterestCollected(address indexed user, uint256 indexed tokenId, uint256 interestAmount);
    event InterestWithdrawn(address indexed to, uint256 amount);
    event TrancheVaultChanged(address indexed oldVault, address indexed newVault);
    event AmmPoolChanged(address indexed oldPool, address indexed newPool);

    // ================= 修饰符 =================
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }

    // ================= 构造函数 =================
    
    constructor(
        address _config,
        address _underlyingTokenAddress,
        address _LTokenAddress
    ) {
        require(_config != address(0), "Config cannot be zero address");
        require(_underlyingTokenAddress != address(0), "UnderlyingToken cannot be zero address");
        require(_LTokenAddress != address(0), "LeverageToken cannot be zero address");

        config = ProtocolConfig(_config);
        underlyingToken = IERC20(_underlyingTokenAddress);
        leverageToken = LeverageToken(_LTokenAddress);
    }

    // ================= 初始化函数 =================
    
    function setTrancheVault(address _newVault) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_newVault != address(0), "Invalid address");
        emit TrancheVaultChanged(address(trancheVault), _newVault);
        trancheVault = ITrancheVault(_newVault);
    }

    function setAmmPool(address _newPool) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_newPool != address(0), "Invalid address");
        emit AmmPoolChanged(address(ammPool), _newPool);
        ammPool = IStableSwapAMM(_newPool);
    }


    // ================= 利率计算函数 =================

    /**
     * @dev 获取 AMM 资金利用率。U越少，该指标越高。返回值为基点（0-10000）。
     */
    function getUtilizationRate() public view returns (uint256) {
        if (address(ammPool) == address(0)) return 0;
        
        uint256 sBalance = ammPool.reserve0() * ammPool.multiplier0();
        uint256 uBalance = ammPool.reserve1() * ammPool.multiplier1();
        uint256 total = sBalance + uBalance;
        
        if (total == 0) return 0;
        
        return (sBalance * config.BPS_DENOMINATOR()) / total;
    }

    /**
     * @dev 依据 Aave 的分段线性模型计算基于利用率的附加利率
     */
    function getUtilizationInterestRate() public view returns (uint256) {
        uint256 utilizationRateBps = getUtilizationRate();
        
        (, uint256 optimalUtilizationRateBps, uint256 slope1Bps, uint256 slope2Bps, ) = config.interestParams();

        if (utilizationRateBps <= optimalUtilizationRateBps) {
            if (optimalUtilizationRateBps == 0) return 0;
            return (utilizationRateBps * slope1Bps) / optimalUtilizationRateBps;
        } else {
            uint256 excessUtilization = utilizationRateBps - optimalUtilizationRateBps;
            uint256 remainingUtilization = config.BPS_DENOMINATOR() - optimalUtilizationRateBps;
            
            if (remainingUtilization == 0) return slope1Bps;
            
            uint256 extraRate = (excessUtilization * slope2Bps) / remainingUtilization;
            return slope1Bps + extraRate;
        }
    }

    /**
     * @dev 获取当前动态计算的年化利率
     */
    function getCurrentInterestRate() public view returns (uint256) {
        (uint256 baseRate,, , , uint256 collateralRiskPremium) = config.interestParams();
        uint256 currentRate = baseRate + getUtilizationInterestRate() + collateralRiskPremium;
        
        uint256 maxInterestRate = config.MAX_INTEREST_RATE();
        if (currentRate > maxInterestRate) {
            return maxInterestRate;
        }
        return currentRate;
    }

    // ================= 核心业务函数 =================
    
    function recordPosition(
        address user, 
        uint256 tokenId, 
        uint256 sAmountInWei,
        uint256 lAmountInWei
    ) external onlyRole(config.VAULT_ROLE())  {
        
        require(lAmountInWei > 0, "Invalid amount");
        
        UserInterestData storage position = userInterestData[user][tokenId];
        
        position.sAmountInWei = sAmountInWei;
        position.lAmountInWei = lAmountInWei;
        position.timestamp = block.timestamp;
        position.accruedInterest = 0;
        position.active = true;
        
        totalActivePositions += 1;
        totalLeverageAmount += lAmountInWei;
        
        emit PositionOpened(user, tokenId, sAmountInWei, lAmountInWei, block.timestamp);

    }

    function updatePosition(
        address user, 
        uint256 tokenId,
        uint256 newSAmountInWei, //new S token amount
        uint256 newLAmountInWei,  //new L token amount
        uint256 deductInterestInWei //檔次扣除的利息
    ) external onlyRole(config.VAULT_ROLE())  
    {

        UserInterestData storage position = userInterestData[user][tokenId];

        //上一次計算以來新的纍計的利息
        uint256 newAccruedInterest = _calculateAccruedInterest(
                position.sAmountInWei, 
                block.timestamp - position.timestamp
            );
        position.accruedInterest += newAccruedInterest; // 更新已计算利息
        position.accruedInterest -= deductInterestInWei; // 先扣除利息，避免用户通过增加杠杆来规避利息扣除
        position.timestamp = block.timestamp;   
        position.sAmountInWei = newSAmountInWei;
        position.lAmountInWei = newLAmountInWei; 

        if(newSAmountInWei == 0)
        {
            position.sAmountInWei = 0;
            position.lAmountInWei = 0;
            position.accruedInterest = 0;
            // position.timestamp = 0;
            position.active = false;
            totalActivePositions -= 1;

        }

    }

    function totalAccruedInterest(
        address user, 
        uint256 tokenId 
    ) external onlyRole(config.VAULT_ROLE()) returns (uint256) {
        
        UserInterestData storage position = userInterestData[user][tokenId];
        
        if (position.sAmountInWei > 0 && position.active) {
            uint256 newAccruedInterest = _calculateAccruedInterest(
                position.sAmountInWei, 
                block.timestamp - position.timestamp
            );
            
            position.accruedInterest += newAccruedInterest;
            position.timestamp = block.timestamp;
            
            totalInterestAccrued += newAccruedInterest;
            
            if (newAccruedInterest > 0) {
                emit InterestAccrued(user, tokenId, newAccruedInterest);
            }
        }
        
        return position.accruedInterest;
    }

    function _calculateAccruedInterest(
        uint256 sAmountInWei,
        uint256 holdingTimeInSeconds
    ) internal view returns (uint256) {


        uint256 currentRate = getCurrentInterestRate();
        uint256 accruedInterest = (sAmountInWei * currentRate * holdingTimeInSeconds) / 
                                   (config.BPS_DENOMINATOR() * config.SECONDS_PER_YEAR());
        return accruedInterest;
    }

    function withdrawInterest(address to, uint256 amount) external onlyRole(config.WITHDRAW_ROLE()) nonReentrant {
        uint256 availableAmount = totalInterestCollected - totalInterestWithdrawn;
        require(amount <= availableAmount, "Insufficient interest balance");
        
        totalInterestWithdrawn += amount;
        underlyingToken.safeTransfer(to, amount);
        
        emit InterestWithdrawn(to, amount);
    }
    
    function emergencyWithdrawInterest(address to) external onlyRole(config.WITHDRAW_ROLE())  nonReentrant {
        uint256 availableAmount = totalInterestCollected - totalInterestWithdrawn;
        require(availableAmount > 0, "No interest available");
        
        totalInterestWithdrawn += availableAmount;
        underlyingToken.safeTransfer(to, availableAmount);
        
        emit InterestWithdrawn(to, availableAmount);
    }    

    // =================相關設置及查詢函數，需有管理员權限 =================
    
    function getUserPosition(address user, uint256 tokenId) external view returns (UserInterestData memory) {
        return userInterestData[user][tokenId];
    }
    
    function previewAccruedInterest(address user, uint256 tokenId) external view returns (uint256) {
        UserInterestData memory position = userInterestData[user][tokenId];
        
        if (position.sAmountInWei == 0 || !position.active) {
            return 0;
        }
        
        uint256 newInterest = _calculateAccruedInterest(
            position.sAmountInWei,
            block.timestamp - position.timestamp
        );
        
        return position.accruedInterest + newInterest;
    }
    
    function getSystemStats() external view returns (
        uint256 accruedAmount,
        uint256 collectedAmount,
        uint256 withdrawnAmount,
        uint256 availableBalance,
        uint256 activePositions,
        uint256 totalLeverage,
        uint256 currentRate
    ) {
        accruedAmount = totalInterestAccrued;
        collectedAmount = totalInterestCollected;
        withdrawnAmount = totalInterestWithdrawn;
        availableBalance = totalInterestCollected - totalInterestWithdrawn;
        activePositions = totalActivePositions;
        totalLeverage = totalLeverageAmount;
        currentRate = getCurrentInterestRate();
    }
    
    
    function calculateInterestForAmount(
        uint256 sAmountInWei,
        uint256 timeInSeconds
    ) external view returns (uint256) {
        return _calculateAccruedInterest(sAmountInWei, timeInSeconds);
    }
    
    function getSystemHealth() external view returns (
        uint256 collectionRate,       
        uint256 utilizationRate,      
        uint256 avgPositionSize,      
        bool isHealthy               
    ) {
        uint256 bps = config.BPS_DENOMINATOR();
        collectionRate = totalInterestAccrued > 0 ? 
            (totalInterestCollected * bps) / totalInterestAccrued : bps;
        
        utilizationRate = totalInterestCollected > 0 ? 
            (totalInterestWithdrawn * bps) / totalInterestCollected : 0;
        
        avgPositionSize = totalActivePositions > 0 ? 
            totalLeverageAmount / totalActivePositions : 0;
        
        isHealthy = collectionRate >= 8000 && utilizationRate <= 9000;
    }
}
