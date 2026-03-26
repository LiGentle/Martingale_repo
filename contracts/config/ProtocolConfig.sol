// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract ProtocolConfig is AccessControl {

    /* ==================== ERRORS ==================== */
    error InvalidFeeBps(uint16 feeBps);
    error InvalidAddress();
    error InvalidOracleParams();
    error InvalidMaxLTVBps(uint256 maxLTVBps);

    /* ==================== ROLES & CONSTANTS ==================== */
    // 權限
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");
    bytes32 public constant WHITELIST_ROLE = keccak256("WHITELIST_ROLE"); 
    bytes32 public constant PARAM_ROLE = keccak256("PARAM_ROLE"); 
    bytes32 public constant WITHDRAW_ROLE = keccak256("WITHDRAW_ROLE"); 
    bytes32 public constant LIQUIDATION_ROLE = keccak256("LIQUIDATION_ROLE");   
    bytes32 public constant AUCTION_ROLE = keccak256("AUCTION_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE"); 
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // 常數
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint256 public constant TIMELOCK_DURATION = 2 days; // Timelock 變數：用於延遲執行 maxLTVInBps 的修改

    // 利率常數
    uint256 public constant SECONDS_PER_YEAR = 365 days;    
    uint256 public constant MAX_INTEREST_RATE = 5000;       
    uint256 public constant MIN_HOLDING_TIME = 1 hours;     
    
    /* ==================== STRUCTS ==================== */
    struct PendingLTVUpdate {
        uint256 newMaxLTVBps;
        uint256 executeTime;
    }

    struct AuctionParams {
        uint256 priceMultiplier;     // 增加起始价格的乘数因子   精度为10000，即12000表示1.2倍
        uint256 resetTime;           // 拍卖有效期 [seconds]
        uint256 priceDropThreshold;  // 拍卖价格下限乘子
        uint256 percentageReward;    // 激励keeper的百分比费用  精度为10000，即100表示1%
        uint256 fixedReward;         // 激励keeper的固定费用 
        uint256 minAuctionAmount;    // 最小购买数量 
    }

    struct InterestParams {
        uint256 baseRateInBps;             // 基础利率（基点，100 = 1%）
        uint256 optimalUtilizationRateBps; // 最佳利用率 (默认 92%)
        uint256 slope1Bps;                 // 利用率 <= optimal 时的最大斜率附加利率 (默认 4%)
        uint256 slope2Bps;                 // 利用率 > optimal 时的最大斜率附加利率 (默认 75%)
        uint256 collateralRiskPremiumInBps;// 抵押风险溢价（基点，100 = 1%）
    }

    struct OracleParams {
        uint256 delay;
        uint256 maxPriceAge;
        uint256 maxPriceDeviationBps; // Maximum allowed price deviation in basis points (e.g., 500 = 5%)
    }

    /* ==================== STATE VARIABLES ==================== */
    uint16 public mintFeeInBps;       // e.g. 30 = 0.30%
    uint16 public burnFeeInBps;       // e.g. 50 = 0.50%
    address public feeRecipient;    // Treasury
    // uint256 public maxPriceAge;     // seconds, e.g. 3600
    uint256 public maxLTVInBps = 7_500; // 75%

    // Oracle Parameters
    OracleParams public oracleParams;

    // Liquidation Parameters
    uint256 public liquidationThreshold = 3 * 10**17;    // 强制清算阈值: 0.3   
    uint256 public liquidationPenalty = 3 * 10**16;      // 清算惩罚金: 0.03    
    bool public liquidationEnabled = true;               // 清算功能是否启用    

    // Auction Parameters
    AuctionParams public auctionParams;
    uint256 public circuitBreaker = 0; // 断路器级别 0-3

    // Interest Parameters
    InterestParams public interestParams;

    PendingLTVUpdate public pendingLTVUpdate;

    /* ==================== EVENTS ==================== */
    // ... [Events omitted for brevity]
    event MintFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event BurnFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event OracleParamsUpdated(uint256 oldDelay, uint256 oldMaxPriceAge, uint256 oldDeviation, uint256 newDelay, uint256 newMaxPriceAge,  uint256 newDeviation);   
    event MaxLTVUpdated(uint256 oldMaxLTVBps, uint256 newMaxLTVBps);
    event MaxLTVUpdateScheduled(uint256 newMaxLTVBps, uint256 executeTime);     
    event LiquidationParamsUpdated(uint256 liquidationThreshold, uint256 liquidationPenalty);
    event LiquidationStatusUpdated(bool enabled);
    event AuctionParamsUpdated();
    event CircuitBreakerUpdated(uint256 level);
    event InterestParamsUpdated();

    /* ==================== CONSTRUCTOR ==================== */
    constructor(
        address safeAddress,
        address _feeRecipient,
        uint16 _mintFeeInBps,
        uint16 _burnFeeInBps,
        uint256 _maxLTVInBps
    ) {
        if (_mintFeeInBps > MAX_FEE_BPS || _burnFeeInBps > MAX_FEE_BPS) {
            revert InvalidFeeBps(_mintFeeInBps > MAX_FEE_BPS ? _mintFeeInBps : _burnFeeInBps);
        }
        if (_maxLTVInBps == 0 || _maxLTVInBps > BPS_DENOMINATOR) revert InvalidMaxLTVBps(_maxLTVInBps);

        _grantRole(DEFAULT_ADMIN_ROLE, safeAddress);
        
        feeRecipient = _feeRecipient;
        mintFeeInBps = _mintFeeInBps;
        burnFeeInBps = _burnFeeInBps;
        maxLTVInBps = _maxLTVInBps;

        // Initialize default oracle params
        oracleParams = OracleParams({
            delay: 3600,
            maxPriceAge: 7200,
            maxPriceDeviationBps: 500 // Default 5% deviation threshold
        });

        // Initialize default auction params
        auctionParams = AuctionParams({
            priceMultiplier: 1 * uint256(BPS_DENOMINATOR),    
            resetTime: 3600,                 
            priceDropThreshold: (9 * uint256(BPS_DENOMINATOR)) / 10,  
            percentageReward: (1 * uint256(BPS_DENOMINATOR)) / 100,    
            fixedReward: 10 * 10**18,        
            minAuctionAmount: 100 * 10**18   
        });

        // Initialize default interest params
        interestParams = InterestParams({
            baseRateInBps: 300,                  
            optimalUtilizationRateBps: 9200,     
            slope1Bps: 400,                      
            slope2Bps: 7500,                     
            collateralRiskPremiumInBps: 0        
        });
    }

    //一次性授予多個地址多個角色，減少多簽操作的繁瑣程度
    function batchGrantRoles(
        bytes32[] calldata roles,
        address[] calldata accounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(roles.length == accounts.length, "Length mismatch");
        for (uint256 i = 0; i < roles.length; i++) {
            _grantRole(roles[i], accounts[i]);
        }
    }

    //更改特定role的角色員，先revoke舊地址的role，再grant新地址的role
    function updateRole(bytes32 role, address oldAccount, address newAccount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAccount != address(0), "Invalid new account");
        _revokeRole(role, oldAccount);
        _grantRole(role, newAccount);
    }

    /* ==================== PARAMETER SETTERS ==================== */
    
    function setmintFeeInBps(uint16 newFeeBps) external onlyRole(PARAM_ROLE) {    
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps(newFeeBps);
        uint16 old = mintFeeInBps;
        mintFeeInBps = newFeeBps;
        emit MintFeeUpdated(old, newFeeBps);
    }
    function setburnFeeInBps(uint16 newFeeBps) external onlyRole(PARAM_ROLE) {    
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFeeBps(newFeeBps);
        uint16 old = burnFeeInBps;
        burnFeeInBps = newFeeBps;
        emit BurnFeeUpdated(old, newFeeBps);
    }
    function setFeeRecipient(address newRecipient) external onlyRole(PARAM_ROLE) {
        if (newRecipient == address(0)) revert InvalidAddress();
        address old = feeRecipient;
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }
    function setOracleParams(uint256 newDelay, uint256 newMaxPriceAge, uint256 newMaxPriceDeviationBps) external onlyRole(PARAM_ROLE) {
        if (newDelay==0 || newMaxPriceAge == 0) revert InvalidOracleParams();
        uint256 oldDelay = oracleParams.delay;
        uint256 oldMaxPriceAge = oracleParams.maxPriceAge;
        uint256 oldMaxPriceDeviationBps = oracleParams.maxPriceDeviationBps;
        oracleParams.delay = newDelay;
        oracleParams.maxPriceAge = newMaxPriceAge;
        oracleParams.maxPriceDeviationBps = newMaxPriceDeviationBps;
        emit OracleParamsUpdated(oldDelay, oldMaxPriceAge,oldMaxPriceDeviationBps, newDelay, newMaxPriceAge, newMaxPriceDeviationBps);
    }
    function setFees(uint16 newmintFeeInBps, uint16 newburnFeeInBps) external onlyRole(PARAM_ROLE) {
        if (newmintFeeInBps > MAX_FEE_BPS) revert InvalidFeeBps(newmintFeeInBps);   
        if (newburnFeeInBps > MAX_FEE_BPS) revert InvalidFeeBps(newburnFeeInBps);   
        uint16 oldMint = mintFeeInBps;
        uint16 oldBurn = burnFeeInBps;
        mintFeeInBps = newmintFeeInBps;
        burnFeeInBps = newburnFeeInBps;
        emit MintFeeUpdated(oldMint, newmintFeeInBps);
        emit BurnFeeUpdated(oldBurn, newburnFeeInBps);
    }

    /* ==================== LIQUIDATION SETTERS ==================== */
    function setLiquidationParams(
        uint256 newLiquidationThreshold,
        uint256 newLiquidationPenalty
    ) external onlyRole(PARAM_ROLE) {
        liquidationThreshold = newLiquidationThreshold;
        liquidationPenalty = newLiquidationPenalty;
        emit LiquidationParamsUpdated(newLiquidationThreshold, newLiquidationPenalty);
    }
    function setLiquidationEnabled(bool enabled) external onlyRole(PARAM_ROLE) {
        liquidationEnabled = enabled;
        emit LiquidationStatusUpdated(enabled);
    }

    /* ==================== AUCTION SETTERS ==================== */
    function setAuctionParams(
        uint256 _priceMultiplier,
        uint256 _resetTime,
        uint256 _priceDropThreshold,
        uint256 _percentageReward,
        uint256 _fixedReward,
        uint256 _minAuctionAmount
    ) external onlyRole(PARAM_ROLE) {
        auctionParams = AuctionParams({
            priceMultiplier: _priceMultiplier,
            resetTime: _resetTime,
            priceDropThreshold: _priceDropThreshold,
            percentageReward: _percentageReward,
            fixedReward: _fixedReward,
            minAuctionAmount: _minAuctionAmount
        });
        emit AuctionParamsUpdated();
    }

    function setCircuitBreaker(uint256 _level) external onlyRole(PARAM_ROLE) {
        circuitBreaker = _level;
        emit CircuitBreakerUpdated(_level);
    }

    /* ==================== INTEREST SETTERS ==================== */
    function setInterestParams(
        uint256 _baseRateInBps,
        uint256 _optimalUtilizationRateBps,
        uint256 _slope1Bps,
        uint256 _slope2Bps,
        uint256 _collateralRiskPremiumInBps
    ) external onlyRole(PARAM_ROLE) {
        require(_baseRateInBps <= MAX_INTEREST_RATE, "Base rate too high");
        require(_slope1Bps <= MAX_INTEREST_RATE, "Slope1 too high");
        require(_slope2Bps <= MAX_INTEREST_RATE, "Slope2 too high");
        require(_collateralRiskPremiumInBps <= MAX_INTEREST_RATE, "Risk premium too high");
        require(_optimalUtilizationRateBps <= BPS_DENOMINATOR, "Optimal rate > 100%");

        interestParams = InterestParams({
            baseRateInBps: _baseRateInBps,
            optimalUtilizationRateBps: _optimalUtilizationRateBps,
            slope1Bps: _slope1Bps,
            slope2Bps: _slope2Bps,
            collateralRiskPremiumInBps: _collateralRiskPremiumInBps
        });
        emit InterestParamsUpdated();
    }

    /* ==================== TIMELOCK LTV UPDATES ==================== */        
    function scheduleSetMaxLTVInBps(uint256 newMaxLTVBps) external onlyRole(PARAM_ROLE) {
        if (newMaxLTVBps == 0 || newMaxLTVBps > BPS_DENOMINATOR) {
            revert InvalidMaxLTVBps(newMaxLTVBps);
        }
        uint256 executeTime = block.timestamp + TIMELOCK_DURATION;
        pendingLTVUpdate = PendingLTVUpdate({
            newMaxLTVBps: newMaxLTVBps,
            executeTime: executeTime
        });
        emit MaxLTVUpdateScheduled(newMaxLTVBps, executeTime);
    }
    function executeSetMaxLTVInBps() external {
        uint256 executeTime = pendingLTVUpdate.executeTime;
        require(executeTime != 0, "No pending LTV update");
        require(block.timestamp >= executeTime, "Timelock has not expired yet");
        uint256 oldMaxLTV = maxLTVInBps;
        uint256 newMaxLTV = pendingLTVUpdate.newMaxLTVBps;
        maxLTVInBps = newMaxLTV;
        delete pendingLTVUpdate;
        emit MaxLTVUpdated(oldMaxLTV, newMaxLTV);
    }

    /* ==================== VIEW / PURE FUNCTIONS ==================== */       
    function calcFee(uint256 amount, uint16 feeBps) public pure returns (uint256) {
        return (amount * feeBps) / BPS_DENOMINATOR;
    }
    function calcMintFee(uint256 amount) external view returns (uint256) {      
        return (amount * mintFeeInBps) / BPS_DENOMINATOR;
    }
    function calcBurnFee(uint256 amount) external view returns (uint256) {      
        return (amount * burnFeeInBps) / BPS_DENOMINATOR;
    }
}