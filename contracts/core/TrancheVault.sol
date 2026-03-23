// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../tokens/StableToken.sol";
import "../tokens/LeverageToken.sol";
import "../config/ProtocolConfig.sol";
import "../interfaces/ITrancheVault.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IInterestManager.sol";
import "../interfaces/IOracleManager.sol";
import "../interfaces/ILiquidationManager.sol";
import "../libraries/DataTypes.sol";

contract TrancheVault is ITrancheVault, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    // ================= Type Declarations =================
    enum State {
        Inception,
        Trading,
        Paused,
        Matured
    }

    // ================= Immutables =================
    // 核心资产合约 - 构造函数设置
    ProtocolConfig public immutable config;
    IERC20 public immutable underlyingToken;              
    StableToken public immutable stableToken;             
    LeverageToken public immutable leverageToken;    
    // uint8 public immutable underlyingTokenDecimals;

    // ================= State Variables =================
    // 周邊模組 (不使用 immutable，以保留升級彈性)
    ITreasury public treasury;
    IInterestManager public interestManager;
    IOracleManager public oracleManager;
    ILiquidationManager public liquidationManager;    // 當前合約狀態
    State public state;

    // 白名單功能
    bool public whitelistMintEnabled = true; // 默认开启白名单铸币，上线后可手动关闭变为公开铸币

    // 统计变量
    uint256 public totalSupplyS;
    uint256 public totalSupplyL;
    uint256 public CollateralInWei; // 所有用户抵押品总和

    // ================= Mappings =================
    mapping(address => bool) public isWhitelisted;
    mapping(address => uint256) public userCollateral; // 用戶抵押品
    mapping(address => EnumerableSet.UintSet) private _userTokenIds; // 用戶擁有的所有L token ID集合

    // ================= Events =================
    event StateTransition(State oldState, State newState);
    event InterestManagerUpdated(address indexed oldInterestManager, address indexed newInterestManager);
    event OracleManagerUpdated(address indexed oldOracleManager, address indexed newOracleManager);
    event LiquidationManagerUpdated(address indexed oldLiquidationManager, address indexed newLiquidationManager);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    
    event WhitelistMintStatusChanged(bool enabled);
    event WhitelistedAdded(address[] accounts);
    event WhitelistedRemoved(address[] accounts);
    
    event Mint(address indexed user, uint256 underlyingAmountInWei, uint256 mintPriceInWei, uint256 LTVInBps, uint256 sAmountInWei, uint256 lAmountInWei);
    event Burn(address indexed user, uint256 tokenId, uint256 sAmountInWei, uint256 lAmountInWei, uint256 underlyingAmountInWei);
    
    event BurnLTokenInLiquidation(address indexed user, uint256 tokenId, uint256 balance);
    event BurnSTokenInLiquidation(address indexed user, uint256 tokenId, uint256 stableAmount);

    // ================= Modifiers =================
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }

    modifier inState(State _state) {
        require(state == _state, "Invalid state: Current state does not match required state");
        _;
    }

    modifier onlyWhitelisted() {
        if (whitelistMintEnabled) {
            _;
        } else {
            _;
        }
    }

    // ================= Constructor =================
    constructor(
        address _config,
        address _underlyingTokenAddr,
        address _STokenAddr,
        address _LTokenAddr
    ) {
        require(_config != address(0), "Invalid config");
        require(_underlyingTokenAddr != address(0), "Invalid underlying token");
        require(_STokenAddr != address(0), "Invalid stable token");
        require(_LTokenAddr != address(0), "Invalid leverage token");

        config = ProtocolConfig(_config);

        underlyingToken = IERC20(_underlyingTokenAddr);
        stableToken = StableToken(_STokenAddr);
        leverageToken = LeverageToken(_LTokenAddr);
        // underlyingTokenDecimals = IERC20Metadata(_underlyingTokenAddr).decimals();
        
        state = State.Inception;
    }

    // ================= External Functions (Settings) =================
    
    function setVaultState(State _newState) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(_newState != state, "State is already set");
        emit StateTransition(state, _newState);
        state = _newState;
    }

    function setInterestManager(address _interestManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        emit InterestManagerUpdated(address(interestManager), _interestManager);
        interestManager = IInterestManager(_interestManager);
    }

    function setOracleManager(address _oracleManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        emit OracleManagerUpdated(address(oracleManager), _oracleManager);
        oracleManager = IOracleManager(_oracleManager);
    }

    function setLiquidationManager(address _liquidationManager) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        emit LiquidationManagerUpdated(address(liquidationManager), _liquidationManager);
        liquidationManager = ILiquidationManager(_liquidationManager);
    }    function setTreasury(address _treasury) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        emit TreasuryUpdated(address(treasury), _treasury);
        treasury = ITreasury(_treasury);
    }

    function setWhitelistMintEnabled(bool _enabled) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        whitelistMintEnabled = _enabled;
        emit WhitelistMintStatusChanged(_enabled);
    }

    function addToWhitelist(address[] calldata accounts) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        for (uint i = 0; i < accounts.length; i++) {
            isWhitelisted[accounts[i]] = true;
        }
        emit WhitelistedAdded(accounts);
    }

    function removeFromWhitelist(address[] calldata accounts) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        for (uint i = 0; i < accounts.length; i++) {
            isWhitelisted[accounts[i]] = false;
        }
        emit WhitelistedRemoved(accounts);
    }

    // ================= External Functions (Core: Mint / Burn) =================
    
    function previewMint(
        uint256 underlyingAmountInWei,
        uint256 LTVInBps
    ) external inState(State.Trading) nonReentrant returns (
        uint256 sAmountInWei,
        uint256 lAmountInWei
    ) {
        (uint underlyingPriceInWei, , bool isValid) = oracleManager.getLatestPriceView();
        require(isValid, "Invalid price");

        uint256 fee = config.calcMintFee(underlyingAmountInWei);//以underlying數量表示的fee
        uint256 underlyingAmountInWeiAfterFee = underlyingAmountInWei - fee;//實際用戶抵押的underlying, 用於mint出S & L
        
        uint256 totalValueInWei = underlyingPriceInWei * underlyingAmountInWeiAfterFee;
        
        sAmountInWei = (totalValueInWei * LTVInBps) / (config.BPS_DENOMINATOR() * 1E18);
        lAmountInWei = (totalValueInWei / 1E18) - sAmountInWei;
    }

    function mint(
        address receiver,
        uint256 underlyingAmountInWei,
        uint256 LTVInBps
    ) external inState(State.Trading) nonReentrant returns (
        uint256 sAmountInWei,
        uint256 lAmountInWei,
        uint256 tokenId
    ) {
        if (whitelistMintEnabled) {
            require(isWhitelisted[receiver], "Receiver not in whitelist");
        }

        (uint mintPriceInWei, , bool isValid) = oracleManager.getLatestPriceView();
        require(isValid, "Invalid price");

        require(LTVInBps > 0 && LTVInBps < config.maxLTVInBps(), "Invalid LTV");

        uint256 mintFee = config.calcMintFee(underlyingAmountInWei);
        uint256 underlyingAmountInWeiAfterFee = underlyingAmountInWei - mintFee;
        
        uint256 totalValue = mintPriceInWei * underlyingAmountInWeiAfterFee;
        
        sAmountInWei = (totalValue * LTVInBps) / (config.BPS_DENOMINATOR() * 1E18);
        lAmountInWei = (totalValue / 1E18) - sAmountInWei;
    
        //
        require(underlyingToken.allowance(msg.sender, address(this)) >= underlyingAmountInWei, "Insufficient allowance");
        
        if (mintFee > 0) {
            underlyingToken.safeTransferFrom(msg.sender, config.feeRecipient(), mintFee);
        }
        
        if (underlyingAmountInWeiAfterFee > 0) {
            underlyingToken.safeTransferFrom(msg.sender, address(treasury), underlyingAmountInWeiAfterFee);
        }

        tokenId = _executeMintCore(
            receiver,
            underlyingAmountInWeiAfterFee,
            mintPriceInWei,
            LTVInBps,
            sAmountInWei,
            lAmountInWei
        );

        //在interestManager中更新状态, 保存在變量中
        //mapping(address => mapping(uint256 => UserInterestData)) public userInterestData;
        interestManager.recordPosition(receiver, tokenId, sAmountInWei, lAmountInWei);

        emit Mint(receiver, underlyingAmountInWeiAfterFee, mintPriceInWei, LTVInBps, sAmountInWei, lAmountInWei);

        return (sAmountInWei, lAmountInWei, tokenId);
    }   

    function burn(
        uint256 tokenId,
        uint256 burnPercentageInBps
    ) external inState(State.Trading) nonReentrant returns (
        uint256 underlyingAmountRedeemedInWei,
        uint256 stableTokenBurnedInWei,
        uint256 leverageTokenBurnedInWei
    ){
        require(burnPercentageInBps > 0 && burnPercentageInBps <= config.BPS_DENOMINATOR(), "Invalid percentage");
        require(leverageToken.balanceOf(msg.sender, tokenId) > 0, "No L tokens to burn");

        (uint256 currentPriceInWei, , bool isValid) = oracleManager.getLatestPriceView();
        require(isValid && currentPriceInWei > 0, "Invalid price");

        (
            uint256 totalUnderlyingAmountInWei, 
            , 
            ,
            uint256 totalSAmountInWei, 
            uint256 totalLAmountInWei, 
            ,
            bool isLocked
        ) = leverageToken.getTokenInfo(tokenId);
        require(!isLocked, "Token is locked");

        uint256 sAmountNeededInWei = (totalSAmountInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();
        uint256 lAmountBurnedInWei = (totalLAmountInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();
        uint256 underlyingAmountInWei = (totalUnderlyingAmountInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();

        require(stableToken.balanceOf(msg.sender) >= sAmountNeededInWei, "Insufficient S balance");
        require(userCollateral[msg.sender] >= underlyingAmountInWei, "Insufficient collateral");

        // 1. 真實扣減利息：從 InterestManager 取得最精確的應扣利息 (USD 價值)
        uint256 exactDeductInterestInUSD = interestManager.updatePosition(msg.sender, tokenId, burnPercentageInBps);
        
        // 2. 將扣除的利息轉換為底層資產數量 (必須被該次 Burn 的抵押品數量 Cap 住，防穿倉超扣)
        uint256 rawUnderlyingToInterest = (exactDeductInterestInUSD * 1e18) / currentPriceInWei;
        uint256 underlyingAmountToInterestManager = rawUnderlyingToInterest > underlyingAmountInWei ? underlyingAmountInWei : rawUnderlyingToInterest;
        
        // 3. 計算用戶實際能拿回多少底層資產
        uint256 remainingUnderlying = underlyingAmountInWei - underlyingAmountToInterestManager;

        uint256 burnFeeInWei = config.calcBurnFee(remainingUnderlying);
        uint256 underlyingAmountToUser = remainingUnderlying - burnFeeInWei;

        // 4. 開始更新 Vault 狀態與銷毀代幣
        // 检查是否被清算保护，如果被保护，说明用户已经支付给treasury，需要从treasury中burn sAmountNeededInWei
        bool islooked = liquidationManager.checkLockStatus(msg.sender, tokenId);
        if(islooked){
            stableToken.burn(address(treasury), sAmountNeededInWei);
        }else{        
            stableToken.burn(msg.sender, sAmountNeededInWei);
        }
        leverageToken.burn(msg.sender, tokenId, lAmountBurnedInWei);

        uint256 newSAmountInWei;
        uint256 newLAmountInWei;
        if (burnPercentageInBps == config.BPS_DENOMINATOR()) {
            _userTokenIds[msg.sender].remove(tokenId);
            leverageToken.deleteTokenInfo(tokenId);
            newSAmountInWei = 0;
            newLAmountInWei = 0;
        } else {
            newSAmountInWei = totalSAmountInWei - sAmountNeededInWei;
            newLAmountInWei = totalLAmountInWei - lAmountBurnedInWei;
            leverageToken.updateStokenAmount(tokenId, newSAmountInWei);
            leverageToken.updateLtokenAmount(tokenId, newLAmountInWei);
            leverageToken.updateUnderlyingAmount(tokenId, totalUnderlyingAmountInWei - underlyingAmountInWei);
        }

        userCollateral[msg.sender] -= underlyingAmountInWei;
        CollateralInWei -= underlyingAmountInWei;
        totalSupplyS -= sAmountNeededInWei;
        totalSupplyL -= lAmountBurnedInWei;

        // 5. 資金劃轉
        if (underlyingAmountToUser > 0) {
            treasury.withdraw(msg.sender, underlyingAmountToUser);
        }
        if (underlyingAmountToInterestManager > 0) {
            treasury.withdraw(address(interestManager), underlyingAmountToInterestManager);
        }
        if (burnFeeInWei > 0) {
            treasury.withdraw(config.feeRecipient(), burnFeeInWei);
        }

        stableTokenBurnedInWei = sAmountNeededInWei;
        leverageTokenBurnedInWei = lAmountBurnedInWei;
        underlyingAmountRedeemedInWei = underlyingAmountToUser;
        emit Burn(msg.sender, tokenId, stableTokenBurnedInWei, leverageTokenBurnedInWei, underlyingAmountRedeemedInWei);
    }

    // ================= Public Functions =================
    
    function previewBurn(
        address user,
        uint256 tokenId,
        uint256 burnPercentageInBps
    ) public view returns (
        uint256 sAmountNeededInWei,
        uint256 lAmountBurnedInWei,
        uint256 underlyingAmountInWei,
        uint256 deductInterestInWei,
        uint256 underlyingAmountToInterestManager,
        uint256 underlyingAmountToUser,
        uint256 burnFeeInWei
    ) {
        require(burnPercentageInBps > 0 && burnPercentageInBps <= config.BPS_DENOMINATOR(), "Invalid percentage");

        (uint256 currentPriceInWei, , bool isValid) = oracleManager.getLatestPriceView();
        require(isValid && currentPriceInWei > 0, "Invalid price");

        (
            uint256 totalUnderlyingAmountInWei, 
            , 
            ,
            uint256 totalSAmountInWei, 
            uint256 totalLAmountInWei, 
            ,
            bool isLocked
        ) = leverageToken.getTokenInfo(tokenId);

        require(!isLocked, "Token is locked");

        sAmountNeededInWei = (totalSAmountInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();
        lAmountBurnedInWei = (totalLAmountInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();
        underlyingAmountInWei = (totalUnderlyingAmountInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();

        //change interest from USD to underlying
        uint256 totalInterestInWei = interestManager.previewAccruedInterest(user, tokenId); 
        deductInterestInWei = (totalInterestInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();
        

        uint256 rawUnderlyingToInterest = (deductInterestInWei * 1e18) / currentPriceInWei;
        underlyingAmountToInterestManager = rawUnderlyingToInterest > underlyingAmountInWei ? underlyingAmountInWei : rawUnderlyingToInterest;

        /*
         * underlyingAmountInWei：由於本次burn需要從colleteral中扣除的縂的Underlying數量
         * rawUnderlyingToInterest: 借貸S需要支付的利息體現為Underlying的數量
         * remainingUnderlying：扣除利息後的Underlying數量
         * underlyingAmountToUser：扣除Burn fee之後實際返回給用戶的Underlying數量
        */
        uint256 remainingUnderlying = underlyingAmountInWei - underlyingAmountToInterestManager;

        burnFeeInWei = config.calcBurnFee(remainingUnderlying);
        underlyingAmountToUser = remainingUnderlying - burnFeeInWei;
    }

    // ================= External Functions (Liquidation Actions) =================
    // ================= External Functions (Liquidation Actions) =================
    function UTAdrs() external view returns (address) {
        return address(underlyingToken);
    }
    function OMAdrs() external view returns (address) {
        return address(oracleManager);
    }
    function freezeStable(address user, uint256 valueToBeFreezed) external onlyRole(config.LIQUIDATION_ROLE()){
        require(stableToken.balanceOf(user) >= valueToBeFreezed, "Insufficient S token balance");
        require(stableToken.allowance(user, address(this)) >= valueToBeFreezed, "Insufficient S token allowance");
        IERC20(address(stableToken)).safeTransferFrom(user, address(treasury), valueToBeFreezed);
    }

    function unfreezeStable(address user, uint256 valueToBeUnfreezed) external onlyRole(config.LIQUIDATION_ROLE()){
        treasury.withdrawS(user, valueToBeUnfreezed);
    }
    
    function burnLTokenFromLiquidation(address user, uint256 tokenId, uint256 balance) external onlyRole(config.LIQUIDATION_ROLE()) {
        leverageToken.burn(user, tokenId, balance);
        leverageToken.updateStokenAmount(tokenId, 0);
        leverageToken.updateLtokenAmount(tokenId, 0);
        leverageToken.updateUnderlyingAmount(tokenId,0);
        totalSupplyL -= balance;
        emit BurnLTokenInLiquidation(user, tokenId, balance);

        uint256 totalInterestInWei = interestManager.previewAccruedInterest(user, tokenId);
        uint256 underlyingAmountToInterestManager; 
        
        (uint256 currentPriceInWei, , bool isValid) = oracleManager.getLatestPriceView();
        
        if (isValid && currentPriceInWei > 0) {
            uint256 deductUnderlyingAmountInWei = totalInterestInWei * 1E18 / currentPriceInWei;    
            underlyingAmountToInterestManager = deductUnderlyingAmountInWei;
        } else {
            underlyingAmountToInterestManager = 0;
        }

        if (underlyingAmountToInterestManager > 0) {
            treasury.withdraw(address(interestManager), underlyingAmountToInterestManager);
        }

        interestManager.updatePosition(user, tokenId, 10000);
    }


    function burnSToken(address kpr, uint256 stableAmount) external onlyRole(config.AUCTION_ROLE()) {
        require(stableToken.balanceOf(kpr) >= stableAmount, "Insufficient S token balance");
        require(stableToken.allowance(kpr, address(this)) >= stableAmount, "Insufficient S token allowance");
        
        IERC20(address(stableToken)).safeTransferFrom(kpr, address(this), stableAmount);
        stableToken.burn(address(this), stableAmount); 
        
        totalSupplyS -= stableAmount; 
    }

    function transferUnderlying(address kpr, uint256 underlyingAmount) external onlyRole(config.AUCTION_ROLE()) {
        require(underlyingToken.balanceOf(address(treasury)) >= underlyingAmount, 'TV/ Insufficient underlying in Treasury');
        treasury.withdraw(kpr, underlyingAmount);
        CollateralInWei -= underlyingAmount; 
    }

    // ================= Internal Functions =================
    
    function _executeMintCore(
        address receiver,
        uint256 underlyingAmountInWeiAfterFee,
        uint256 mintPriceInWei,
        uint256 LTVInBps,
        uint256 sAmountInWei,
        uint256 lAmountInWei
    ) internal returns (uint256 tokenId) {
        userCollateral[receiver] += underlyingAmountInWeiAfterFee;
        CollateralInWei += underlyingAmountInWeiAfterFee;

        stableToken.mint(receiver, sAmountInWei);
        
        tokenId = leverageToken.mint(
            receiver,
            underlyingAmountInWeiAfterFee,
            mintPriceInWei, 
            LTVInBps,            
            sAmountInWei,
            lAmountInWei
        );

        

        totalSupplyS += sAmountInWei;
        totalSupplyL += lAmountInWei;

        _userTokenIds[receiver].add(tokenId);
        
        return tokenId;
    }

    // ================= Read-Only / View Functions =================
    
    function getUserTokenIds(address user) external view returns (uint256[] memory) {
        uint256 length = _userTokenIds[user].length();
        uint256[] memory tokens = new uint256[](length);
        for (uint256 i = 0; i < length; ++i) {
            tokens[i] = _userTokenIds[user].at(i);
        }
        return tokens;
    }
    
    function getUserCollateral(address user) external view returns (uint256) {
        return userCollateral[user];
    }
    
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
    ) {
        balance = leverageToken.balanceOf(user, tokenId);
        require(balance > 0, "User does not hold this token");

        (
            uint256 underlyingAmountInWei, 
            ,,
            uint256 sAmountInWei, 
            uint256 lAmountInWei, 
            ,   
        ) = leverageToken.getTokenInfo(tokenId);
        
        accruedInterestInWei = interestManager.previewAccruedInterest(user, tokenId);
        
        uint256 userAssetValue = underlyingAmountInWei * currentPriceInWei; 
        uint256 debtValue = sAmountInWei * 1E18; 
        
        if (userAssetValue <= debtValue) {
            grossNavInWei = 0; 
        } else {
            uint256 numerator = userAssetValue - debtValue;
            grossNavInWei = numerator / lAmountInWei;
        }

        totalValueInWei = lAmountInWei * grossNavInWei / 1E18;
        
        if (totalValueInWei >= accruedInterestInWei) {
            totalNetValueInWei = totalValueInWei - accruedInterestInWei;
            uint256 interestPerTokenInWei = (accruedInterestInWei * 1E18) / lAmountInWei;
            netNavInWei = grossNavInWei - interestPerTokenInWei;
        } else {
            netNavInWei = 0;
            totalNetValueInWei = 0;
        }
    }
}

