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

    // ================= 全局状态变量 =================
    uint256 public globalDebtIndex = 1e18; //初始借貸1元, 按照動態利息, 逐漸纍計出來的指數。
    uint256 public lastUpdateTimestamp;

    
    // ================= 利息统计 =================
    
    uint256 public totalInterestAccrued;                   // 累计产生的利息
    uint256 public totalInterestCollected;                 // 累计收取的利息
    uint256 public totalInterestWithdrawn;                 // 累计提取的利息
    uint256 public totalActivePositions;                   // 活跃持仓数量
    uint256 public totalLeverageAmount;                    // 总杠杆金额
    uint256 public totalStableAmount;                      // L token总借出資金
    uint256 public totalScaledStableAmount;                // 全局 S 代币缩放份额总计 (用于 O(1) 计算全系统实时未结利息)
    
    // ================= 用户持仓数据 =================
    
    struct UserInterestData {
        uint256 scaledSAmount;          // [核心] 按照全局指數縮放的 S 代幣份額（Shares），決定總負債
        uint256 principalSAmount;       // 記錄用戶真實借出的 S 代幣「本金」。僅用於分辨總債務中哪部分是利息
        uint256 LAmount;                // 槓桿代幣數量（維持原樣，用於計算槓桿率和清算）。多少LAmount-->借貸多少principalSAmount
        bool active;                    // 是否活跃
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

    //所有會改變狀態的核心函數套用它，確保每次操作前都先更新全局利息指數
    modifier accruePositionInterest() {
        updateGlobalIndex();
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

    // 每次有操作前，先更新全局指数
    function updateGlobalIndex() public {
        if (block.timestamp == lastUpdateTimestamp) return;
        
        if (totalStableAmount > 0) { 
            uint256 deltaTime = block.timestamp - lastUpdateTimestamp;
            
            // 1. 取得年化利率 (BPS轉換為小數，使用 1e18 精度)
            // 例如 5000 BPS = 50% = 0.5 * 1e18 = 500,000,000,000,000,000
            uint256 annualRateWad = (getCurrentInterestRate() * 1e18) / config.BPS_DENOMINATOR();
            
            // 2. 計算每秒利率 (1e18 精度，解決了歸零 Bug)
            uint256 ratePerSecondWad = annualRateWad / config.SECONDS_PER_YEAR();
            
            // 3. Aave 的按秒複利近似算法（展開前兩階）
            // 第一階: r * t
            uint256 linearInterest = ratePerSecondWad * deltaTime;
            
            // 第二階: r^2 * t * (t-1) / 2
            uint256 quadraticInterest = 0;
            if (deltaTime > 1) {
                quadraticInterest = (ratePerSecondWad * ratePerSecondWad * deltaTime * (deltaTime - 1)) / (2 * 1e18);
            }
            
            // 4. 當前這段時間的複利乘數 = 1 + 第一階 + 第二階 
            uint256 compoundedMultiplier = 1e18 + linearInterest + quadraticInterest;
            
            // 5. 更新全局 Index
            globalDebtIndex = (globalDebtIndex * compoundedMultiplier) / 1e18;
        }
        
        lastUpdateTimestamp = block.timestamp;
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
    ) external onlyRole(config.VAULT_ROLE()) accruePositionInterest {
        
        require(lAmountInWei > 0, "Invalid amount");
        
        UserInterestData storage position = userInterestData[user][tokenId];
        
        // 算出該筆本金在目前 Index 下對應的份額 (Scaled Amount)
        // 因為有 accruePositionInterest，這裡的 globalDebtIndex 絕對是最新的
        uint256 scaledSAmount = (sAmountInWei * 1e18) / globalDebtIndex;
        
        position.scaledSAmount = scaledSAmount;
        position.principalSAmount = sAmountInWei;
        position.LAmount = lAmountInWei;
        position.active = true;
        
        totalActivePositions += 1;
        totalLeverageAmount += lAmountInWei;
        totalStableAmount += sAmountInWei;
        totalScaledStableAmount += scaledSAmount;
        
        emit PositionOpened(user, tokenId, sAmountInWei, lAmountInWei, block.timestamp);

    }

    //在用戶burn時調用
    function updatePosition(
        address user, 
        uint256 tokenId,
        uint256 burnPercentageInBps // 0-10000，表示本次 burn 的比例
    ) external onlyRole(config.VAULT_ROLE()) accruePositionInterest returns (uint256 interestAmount)
    {
        require(burnPercentageInBps > 0 && burnPercentageInBps <= config.BPS_DENOMINATOR(), "Invalid burn percentage");

        UserInterestData storage position = userInterestData[user][tokenId];
        require(position.active, "Position not active");

        // 1. 在扣減之前，先計算出該用戶這部分倉位「原本」欠了多少利息
        //    因為已經有了 accruePositionInterest，此時 globalDebtIndex 是最新的。
        //    這一步是為了統計系統收集到的總利息，並回傳給 Vault 進行實際的扣款。
        uint256 currentTotalDebt = (position.scaledSAmount * globalDebtIndex) / 1e18;
        uint256 totalInterest = currentTotalDebt > position.principalSAmount ? currentTotalDebt - position.principalSAmount : 0;
        
        // 這次 Burn 應該償還/扣除的利息
        interestAmount = (totalInterest * burnPercentageInBps) / config.BPS_DENOMINATOR();

        // 更新系統宏觀統計
        totalInterestAccrued += interestAmount;
        totalInterestCollected += interestAmount;
        
        // 紀錄這次 burn 掉的 S 和 L 的實際數量，用於更新全局變量
        uint256 burnedSAmount = (position.principalSAmount * burnPercentageInBps) / config.BPS_DENOMINATOR();
        uint256 burnedLAmount = (position.LAmount * burnPercentageInBps) / config.BPS_DENOMINATOR();

        // 2. 這才是縮放模型最漂亮的地方：按比例直接扣減份額和本金
        uint256 burnedScaledSAmount = (position.scaledSAmount * burnPercentageInBps) / config.BPS_DENOMINATOR();
        position.scaledSAmount -= burnedScaledSAmount;
        position.principalSAmount -= burnedSAmount;
        position.LAmount -= burnedLAmount;
        
        // 更新全局借貸總量
        totalStableAmount -= burnedSAmount;
        totalLeverageAmount -= burnedLAmount;
        totalScaledStableAmount -= burnedScaledSAmount;

        // 3. 如果全部 Burn 完（或剩餘極小塵埃），關閉倉位
        if (burnPercentageInBps == config.BPS_DENOMINATOR() || position.principalSAmount == 0) {
            position.scaledSAmount = 0;
            position.principalSAmount = 0;
            position.LAmount = 0;
            position.active = false;
            totalActivePositions -= 1;
        }

        if (interestAmount > 0) {
            emit InterestCollected(user, tokenId, interestAmount);
        }

        return interestAmount;
    }

    function previewAccruedInterest(address user, uint256 tokenId) external view returns (uint256) {
        UserInterestData memory position = userInterestData[user][tokenId];
        
        return _calculateAccruedInterest(position);
    }
    

    function _calculateAccruedInterest(UserInterestData memory position) internal view returns (uint256) {
        if (!position.active || position.scaledSAmount == 0) {
            return 0;
        }

        // 預覽最新的 Index
        uint256 pendingIndex = globalDebtIndex;
        if (block.timestamp > lastUpdateTimestamp && totalStableAmount > 0) {
            uint256 deltaTime = block.timestamp - lastUpdateTimestamp;
            uint256 annualRateWad = (getCurrentInterestRate() * 1e18) / config.BPS_DENOMINATOR();
            uint256 ratePerSecondWad = annualRateWad / config.SECONDS_PER_YEAR();
            
            uint256 linearInterest = ratePerSecondWad * deltaTime;
            uint256 quadraticInterest = 0;
            if (deltaTime > 1) {
                quadraticInterest = (ratePerSecondWad * ratePerSecondWad * deltaTime * (deltaTime - 1)) / (2 * 1e18);
            }
            uint256 compoundedMultiplier = 1e18 + linearInterest + quadraticInterest;
            pendingIndex = (pendingIndex * compoundedMultiplier) / 1e18;
        }

        // 計算目前總債務 = 份額 (Scaled Amount) * 最新 Index
        uint256 currentTotalDebt = (position.scaledSAmount * pendingIndex) / 1e18;

        // 利息 = 總債務 - 最初借出的本金
        if (currentTotalDebt > position.principalSAmount) {
            return currentTotalDebt - position.principalSAmount;
        }
        
        return 0;
    }

    function withdrawInterest(address to, uint256 amount) external onlyRole(config.WITHDRAW_ROLE()) nonReentrant {
        uint256 availableAmount = totalInterestCollected - totalInterestWithdrawn;
        require(amount <= availableAmount, "Insufficient interest balance");
        
        totalInterestWithdrawn += amount;
        
        // ⚠️ Architecture Note: If InterestManager doesn't actually hold the funds (but Vault does), 
        // you should call vault.transfer() instead of underlyingToken.safeTransfer(to, amount)
        underlyingToken.safeTransfer(to, amount);
        
        emit InterestWithdrawn(to, amount);
    }
    
    function emergencyWithdrawInterest(address to) external onlyRole(config.WITHDRAW_ROLE())  nonReentrant {
        // 使用真實的代幣餘額來做緊急提取
        uint256 availableAmount = underlyingToken.balanceOf(address(this));
        require(availableAmount > 0, "No interest available");
        
        totalInterestWithdrawn += availableAmount;
        underlyingToken.safeTransfer(to, availableAmount);
        
        emit InterestWithdrawn(to, availableAmount);
    }    

    // =================相關設置及查詢函數，需有管理员權限 =================
    
    function getUserPosition(address user, uint256 tokenId) external view returns (UserInterestData memory) {
        return userInterestData[user][tokenId];
    }
    

    function getGlobalUnpaidInterest() public view returns (uint256) {
        if (totalScaledStableAmount == 0) return 0;

        uint256 pendingIndex = globalDebtIndex;
        if (block.timestamp > lastUpdateTimestamp && totalStableAmount > 0) {
            uint256 deltaTime = block.timestamp - lastUpdateTimestamp;
            uint256 annualRateWad = (getCurrentInterestRate() * 1e18) / config.BPS_DENOMINATOR();
            uint256 ratePerSecondWad = annualRateWad / config.SECONDS_PER_YEAR();
            
            uint256 linearInterest = ratePerSecondWad * deltaTime;
            uint256 quadraticInterest = 0;
            if (deltaTime > 1) {
                quadraticInterest = (ratePerSecondWad * ratePerSecondWad * deltaTime * (deltaTime - 1)) / (2 * 1e18);
            }
            uint256 compoundedMultiplier = 1e18 + linearInterest + quadraticInterest;
            pendingIndex = (pendingIndex * compoundedMultiplier) / 1e18;
        }

        uint256 currentTotalGlobalDebt = (totalScaledStableAmount * pendingIndex) / 1e18;
        if (currentTotalGlobalDebt > totalStableAmount) {
            return currentTotalGlobalDebt - totalStableAmount;
        }
        return 0;
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
        // 全局總產生利息 = 已經收取過的 + 目前未結算的
        accruedAmount = totalInterestCollected + getGlobalUnpaidInterest();
        collectedAmount = totalInterestCollected;
        withdrawnAmount = totalInterestWithdrawn;
        availableBalance = totalInterestCollected - totalInterestWithdrawn;
        activePositions = totalActivePositions;
        totalLeverage = totalLeverageAmount;
        currentRate = getCurrentInterestRate();
    }
    
    function getSystemHealth() external view returns (
        uint256 collectionRate,       
        uint256 utilizationRate,      
        uint256 avgPositionSize,      
        bool isHealthy               
    ) {
        uint256 bps = config.BPS_DENOMINATOR();
        
        uint256 currentAccruedAmount = totalInterestCollected + getGlobalUnpaidInterest();
        
        collectionRate = currentAccruedAmount > 0 ? 
            (totalInterestCollected * bps) / currentAccruedAmount : bps;
        
        utilizationRate = totalInterestCollected > 0 ? 
            (totalInterestWithdrawn * bps) / totalInterestCollected : 0;
        
        avgPositionSize = totalActivePositions > 0 ? 
            totalLeverageAmount / totalActivePositions : 0;
        
        isHealthy = collectionRate >= 8000 && utilizationRate <= 9000;
    }
}
