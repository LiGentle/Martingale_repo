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
import "../interfaces/ITreasury.sol";
import "../interfaces/IInterestManager.sol";
import "../interfaces/IOracleManager.sol";
import "../interfaces/ILiquidationManager.sol";
import "../libraries/DataTypes.sol";

contract TrancheVault is ReentrancyGuard {
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
    bool private _systemInitialized = false;

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
    event SystemInitialized(address indexed interestManager, address indexed oracleManager);
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
        (uint underlyingPriceInWei, , bool isValid) = oracleManager.getLatestPriceView(address(underlyingToken));
        require(isValid, "Invalid price");

        uint256 fee = config.calcMintFee(underlyingAmountInWei);
        uint256 underlyingAmountInWeiAfterFee = underlyingAmountInWei - fee;
        
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

        (uint mintPriceInWei, , bool isValid) = oracleManager.getLatestPriceView(address(underlyingToken));
        require(isValid, "Invalid price");

        require(LTVInBps > 0 && LTVInBps < config.maxLTVInBps(), "Invalid LTV");

        uint256 mintFee = config.calcMintFee(underlyingAmountInWei);
        uint256 underlyingAmountInWeiAfterFee = underlyingAmountInWei - mintFee;
        
        uint256 totalValue = mintPriceInWei * underlyingAmountInWeiAfterFee;
        
        sAmountInWei = (totalValue * LTVInBps) / (config.BPS_DENOMINATOR() * 1E18);
        lAmountInWei = (totalValue / 1E18) - sAmountInWei;
    
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

        //在interestManager/LiquidationManager中更新状态, 分別保存在以下兩個變量中
        //mapping(address => mapping(uint256 => UserInterestData)) public userInterestData;
        //mapping(address => mapping(uint256 => UserLiquidationStatus)) public userLiquidationStatus;
        liquidationManager.updateLiquidationStatus(receiver, tokenId, lAmountInWei);
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

        // (uint256 underlyingPriceInWei, , bool isValid) = oracleManager.getLatestPriceView(address(underlyingToken));
        // require(isValid && underlyingPriceInWei > 0, "Invalid price");

        (
            uint256 sAmountNeededInWei, //實際匹配的S token數量
            uint256 lAmountBurnedInWei, //實際burn掉的L token數量
            uint256 underlyingAmountInWei,  //扣除利息前應該返還的underlying 數量
            uint256 deductInterestInWei, //檔次扣除利息金額：截至執行previewBurn時刻，纍計的利息*檔次百分比
            uint256 underlyingAmountToInterestManager, //檔次扣除金額以underlying支付的實際數量
            uint256 underlyingAmountToUser,//實際返回給用戶的underlying數量
            uint256 burnFeeInWei //
        ) = previewBurn(tokenId, burnPercentageInBps);



        require(stableToken.balanceOf(msg.sender) >= sAmountNeededInWei, "Insufficient S balance");
        require(userCollateral[msg.sender] >= underlyingAmountInWei, "Insufficient collateral");

        

        stableToken.burn(msg.sender, sAmountNeededInWei);
        leverageToken.burn(msg.sender, tokenId, lAmountBurnedInWei);

        uint256 newSAmountInWei;
        uint256 newLAmountInWei;
        if (burnPercentageInBps == config.BPS_DENOMINATOR()) {
            _userTokenIds[msg.sender].remove(tokenId);
            leverageToken.deleteTokenInfo(tokenId);
            newSAmountInWei = 0;
            newLAmountInWei = 0;
        } else {
            (uint256 totalUnderlyingAmountInWei, , , uint256 totalSAmountInWei, uint256 totalLAmountInWei, , ) = leverageToken.getTokenInfo(tokenId);
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



        if (underlyingAmountToUser > 0) {
            treasury.withdraw(msg.sender, underlyingAmountToUser);
        }
        if (underlyingAmountToInterestManager > 0) {
            treasury.withdraw(address(interestManager), underlyingAmountToInterestManager);
        }
        if (burnFeeInWei > 0) {
            treasury.withdraw(config.feeRecipient(), burnFeeInWei);
        }

        //在LiquidationManager & InterestManager 中信息
        liquidationManager.updateLiquidationStatus(msg.sender, tokenId, newLAmountInWei);
        interestManager.updatePosition(msg.sender, tokenId,newSAmountInWei,newLAmountInWei, deductInterestInWei);

        stableTokenBurnedInWei = sAmountNeededInWei;
        leverageTokenBurnedInWei = lAmountBurnedInWei;
        underlyingAmountRedeemedInWei = underlyingAmountToUser;
        emit Burn(msg.sender, tokenId, stableTokenBurnedInWei, leverageTokenBurnedInWei, underlyingAmountRedeemedInWei);
    }

    // ================= Public Functions =================
    
    function previewBurn(
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

        (uint256 currentPriceInWei, , bool isValid) = oracleManager.getLatestPriceView(address(underlyingToken));
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
        uint256 totalInterestInWei = interestManager.previewAccruedInterest(address(0), tokenId); 
        deductInterestInWei = (totalInterestInWei * burnPercentageInBps) / config.BPS_DENOMINATOR();
        

        uint256 deductUnderlyingAmountInWei = (deductInterestInWei * 1e18) / currentPriceInWei;
        underlyingAmountToInterestManager = deductUnderlyingAmountInWei;

        uint256 remainingUnderlying = underlyingAmountInWei > underlyingAmountToInterestManager 
            ? underlyingAmountInWei - underlyingAmountToInterestManager 
            : 0;

        burnFeeInWei = config.calcBurnFee(remainingUnderlying);
        underlyingAmountToUser = remainingUnderlying - burnFeeInWei;
    }

    // ================= External Functions (Liquidation Actions) =================
    
    function burnLTokenFromLiquidation(address user, uint256 tokenId, uint256 balance) external onlyRole(config.LIQUIDATION_ROLE()) {
        leverageToken.burn(user, tokenId, balance);
        totalSupplyL -= balance;
        emit BurnLTokenInLiquidation(user, tokenId, balance);

        uint256 totalInterestInWei = interestManager.previewAccruedInterest(user, tokenId);
        uint256 underlyingAmountToInterestManager; 
        
        (uint256 currentPriceInWei, , bool isValid) = oracleManager.getLatestPriceView(address(underlyingToken));
        
        if (isValid && currentPriceInWei > 0) {
            uint256 deductUnderlyingAmountInWei = totalInterestInWei * 1e18 / currentPriceInWei;    
            underlyingAmountToInterestManager = deductUnderlyingAmountInWei;
        } else {
            underlyingAmountToInterestManager = 0;
        }

        if (underlyingAmountToInterestManager > 0) {
            underlyingToken.safeTransfer(address(interestManager), underlyingAmountToInterestManager);
        }

        interestManager.updatePosition(user, tokenId, 0,0,totalInterestInWei);
    }

    function backToUser(address user, uint256 amountToUser) external onlyRole(config.AUCTION_ROLE()) {
        underlyingToken.safeTransfer(user, amountToUser);
    } 

    function burnSToken(address kpr, uint256 stableAmount) external onlyRole(config.AUCTION_ROLE()) {
        require(stableToken.balanceOf(kpr) >= stableAmount, "Insufficient S token balance");
        require(stableToken.allowance(kpr, address(this)) >= stableAmount, "Insufficient S token allowance");
        
        IERC20(address(stableToken)).safeTransferFrom(kpr, address(this), stableAmount);
        stableToken.burn(address(this), stableAmount); 
        
        totalSupplyS -= stableAmount; 
    }

    function transferUnderlyingToKpr(address kpr, uint256 underlyingAmount) external onlyRole(config.AUCTION_ROLE()) {
        require(underlyingToken.balanceOf(address(this)) >= underlyingAmount, 'underlyingType amount not enough');
        underlyingToken.safeTransfer(kpr, underlyingAmount);
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

