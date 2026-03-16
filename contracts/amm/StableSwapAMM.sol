// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../tokens/LPToken.sol";
import "../config/ProtocolConfig.sol";

/// @title StableSwap AMM Pool
/// @notice 依據 Curve StableSwap 不變量 (Invariant) 設計的雙穩定幣流動性池
contract StableSwapAMM is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant N_COINS = 2;
    uint256 public constant MAX_A = 1000000;
    uint256 public constant FEE_DENOMINATOR = 10000;

    ProtocolConfig public immutable config;
    IERC20 public immutable token0; // S Token (預設 18 decimals)
    IERC20 public immutable token1; // USDC/USDT (預設 6 decimals)
    LPToken public immutable lpToken;

    uint256 public immutable multiplier0;
    uint256 public immutable multiplier1;

    // 實際存儲的底層代幣餘額
    uint256 public reserve0;
    uint256 public reserve1;

    // Amplification 係數
    uint256 public A; 

    // 手續費率: 10 = 0.1% 
    uint256 public fee;
    // 管理費提成比例: 50% = 5000 (基數 10000)
    uint256 public adminFeeRate; 

    event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 lpTokensMinted);
    event RemoveLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 lpTokensBurned);
    event Swap(address indexed user, uint256 tokenIn, uint256 tokenOut, uint256 amountIn, uint256 amountOut);

    constructor(
        address _config,
        address _token0,
        address _token1,
        string memory _lpName,
        string memory _lpSymbol,
        uint256 _A,
        uint256 _fee,
        uint256 _adminFeeRate
    ) {
        require(_config != address(0), "Invalid config");
        require(_token0 != address(0) && _token1 != address(0), "Invalid tokens");
        require(_A > 0 && _A < MAX_A, "Invalid A");
        require(_fee <= 500, "Fee too high"); // Max fee 5%
        require(_adminFeeRate <= 10000, "Invalid admin fee");

        config = ProtocolConfig(_config);
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        
        uint8 dec0 = IERC20Metadata(_token0).decimals();
        uint8 dec1 = IERC20Metadata(_token1).decimals();
        
        multiplier0 = 10 ** (18 - dec0);
        multiplier1 = 10 ** (18 - dec1);

        A = _A;
        fee = _fee;
        adminFeeRate = _adminFeeRate;

        lpToken = new LPToken(_lpName, _lpSymbol);
    }

    /* ================= 數學核心邏輯 (Curve Invariant) ================= */

    function _xp() internal view returns (uint256[2] memory xp) {
        xp[0] = reserve0 * multiplier0;
        xp[1] = reserve1 * multiplier1;
    }

    /// @dev 計算 D 值 (總流動性不變量)
    function _getD(uint256[2] memory xp, uint256 amp) internal pure returns (uint256) {
        uint256 s = xp[0] + xp[1];
        if (s == 0) return 0;

        uint256 d = s;
        uint256 Ann = amp * N_COINS * N_COINS; // A * n^n
        for (uint256 i = 0; i < 255; i++) {
            uint256 dp = d;
            dp = (dp * d) / (xp[0] * N_COINS);
            dp = (dp * d) / (xp[1] * N_COINS);
            
            uint256 prevD = d;
            // 避免除零和溢出
            d = ((Ann * s + dp * N_COINS) * d) / ((Ann - 1) * d + dp * (N_COINS + 1));
            
            if (d > prevD) {
                if (d - prevD <= 1) return d;
            } else {
                if (prevD - d <= 1) return d;
            }
        }
        revert("D not converging");
    }

    /// @dev 計算給定輸入後，另一端代幣應有的基準存量
    function _getY(uint256 i, uint256 j, uint256 x, uint256[2] memory xp, uint256 amp) internal pure returns (uint256) {
        require(i != j, "Same token");
        require(i < N_COINS && j < N_COINS, "Index bounds");

        uint256 Ann = amp * N_COINS * N_COINS;
        uint256 d = _getD(xp, amp);
        
        uint256 c = d;
        uint256 s = x;

        c = (c * d) / (x * N_COINS);
        c = (c * d) / (Ann * N_COINS);

        uint256 b = s + d / Ann;
        uint256 y = d;

        for (uint256 k = 0; k < 255; k++) {
            uint256 prevY = y;
            y = (y * y + c) / (2 * y + b - d);
            
            if (y > prevY) {
                if (y - prevY <= 1) return y;
            } else {
                if (prevY - y <= 1) return y;
            }
        }
        revert("Y not converging");
    }

    /* ================= 核心交易與池操作 ================= */

    /**
     * @dev 添加流動性，按照當前曲線定價產出對應比例的 LP Token
     */
    function addLiquidity(uint256 amount0, uint256 amount1, uint256 minLpMinted) external nonReentrant returns (uint256) {
        require(amount0 > 0 || amount1 > 0, "Zero amounts");
        
        uint256[2] memory xp = _xp();
        uint256 d0 = 0;
        if (lpToken.totalSupply() > 0) {
            d0 = _getD(xp, A);
        }

        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
            reserve0 += amount0;
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
            reserve1 += amount1;
        }

        uint256[2] memory xpNew = _xp();
        uint256 d1 = _getD(xpNew, A);
        require(d1 > d0, "D must increase");

        uint256 mintAmount;
        uint256 lpSupply = lpToken.totalSupply();

        if (lpSupply == 0) {
            mintAmount = d1;
            // 鎖定微量 LP 到死賬戶，防止第一筆被攻擊
            lpToken.mint(address(0xdead), 1000);
            mintAmount -= 1000;
        } else {
            mintAmount = (lpSupply * (d1 - d0)) / d0;
        }

        require(mintAmount >= minLpMinted, "Slippage error: mintAmount < minLpMinted");
        lpToken.mint(msg.sender, mintAmount);

        emit AddLiquidity(msg.sender, amount0, amount1, mintAmount);
        return mintAmount;
    }

    /**
     * @dev 移除流動性（按比例）
     */
    function removeLiquidity(uint256 lpAmount, uint256 minAmount0, uint256 minAmount1) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(lpAmount > 0, "Zero amount");
        uint256 lpSupply = lpToken.totalSupply();
        require(lpSupply >= lpAmount, "Insufficient supply");

        amount0 = (reserve0 * lpAmount) / lpSupply;
        amount1 = (reserve1 * lpAmount) / lpSupply;

        require(amount0 >= minAmount0 && amount1 >= minAmount1, "Slippage error: received amounts < minAmounts");

        reserve0 -= amount0;
        reserve1 -= amount1;

        lpToken.burn(msg.sender, lpAmount);
        
        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);

        emit RemoveLiquidity(msg.sender, amount0, amount1, lpAmount);
    }

    /**
     * @dev 預測兌換的輸出量 (供前端查詢)
     */
    function getExpectedReturn(uint256 i, uint256 j, uint256 dx) public view returns (uint256 dyNetOut) {
        uint256[2] memory xp = _xp();
        uint256 x = xp[i] + dx * (i == 0 ? multiplier0 : multiplier1);
        uint256 y = _getY(i, j, x, xp, A);
        uint256 dy = xp[j] - y - 1; 

        uint256 dyFee = (dy * fee) / FEE_DENOMINATOR;
        uint256 dyNet18 = dy - dyFee;
        
        dyNetOut = dyNet18 / (j == 0 ? multiplier0 : multiplier1);
    }

    /**
     * @dev 執行穩定幣兌換 (Swap)
     */
    function swap(uint256 i, uint256 j, uint256 dx, uint256 minDy) external nonReentrant returns (uint256 dyNetOut) {
        require(i != j && i < N_COINS && j < N_COINS, "Invalid index");
        require(dx > 0, "Zero swap amount");

        IERC20 tokenIn = i == 0 ? token0 : token1;
        IERC20 tokenOut = j == 0 ? token0 : token1;

        tokenIn.safeTransferFrom(msg.sender, address(this), dx);

        uint256[2] memory xp = _xp();
        uint256 x = xp[i] + dx * (i == 0 ? multiplier0 : multiplier1);
        uint256 y = _getY(i, j, x, xp, A);
        
        uint256 dy = xp[j] - y - 1; 
        uint256 dyFee = (dy * fee) / FEE_DENOMINATOR;
        uint256 dyAdminFee = (dyFee * adminFeeRate) / FEE_DENOMINATOR;

        // 計算實際匯出的餘額和池子會減去的帳本餘額
        uint256 dyNet18 = dy - dyFee;
        uint256 dyReserveDecrease18 = dy - dyAdminFee; 

        dyNetOut = dyNet18 / (j == 0 ? multiplier0 : multiplier1);
        uint256 dyReserveDecreaseOut = dyReserveDecrease18 / (j == 0 ? multiplier0 : multiplier1);

        require(dyNetOut >= minDy, "Slippage error: output < minDy");

        // 更新儲備
        if (i == 0) {
            reserve0 += dx;
            reserve1 -= dyReserveDecreaseOut;
        } else {
            reserve1 += dx;
            reserve0 -= dyReserveDecreaseOut;
        }

        tokenOut.safeTransfer(msg.sender, dyNetOut);
        emit Swap(msg.sender, i, j, dx, dyNetOut);
    }

    /* ================= 管理員權限設定 ================= */

    // 建立一個統一的 Modifier，向 ProtocolConfig 查詢權限
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }

    /**
     * @dev 修改放大係數 A，僅限 PARAM_ROLE 調用
     */
    function setA(uint256 _A) external onlyRole(config.PARAM_ROLE()) {
        require(_A > 0 && _A < MAX_A, "Invalid A");
        A = _A;
    }

    /**
     * @dev 修改交易手續費率與管理費提成，僅限 PARAM_ROLE 調用
     */
    function setFee(uint256 _fee, uint256 _adminFeeRate) external onlyRole(config.PARAM_ROLE()) {
        require(_fee <= 500, "Fee too high"); // Max fee 5% 
        require(_adminFeeRate <= 10000, "Invalid admin fee rate");
        fee = _fee;
        adminFeeRate = _adminFeeRate;
    }

    /**
     * @dev 提取因為手續費累積產生的協議收益 (超出 Reserve 儲備的部分)，直接發送到 ProtocolConfig 中的 feeRecipient
     */
    function withdrawAdminFees() external nonReentrant onlyRole(config.WITHDRAW_ROLE()) {
        uint256 currentBalance0 = token0.balanceOf(address(this));
        uint256 currentBalance1 = token1.balanceOf(address(this));

        uint256 feeToCollect0 = currentBalance0 > reserve0 ? currentBalance0 - reserve0 : 0;
        uint256 feeToCollect1 = currentBalance1 > reserve1 ? currentBalance1 - reserve1 : 0;

        address feeRecipient = config.feeRecipient();
        require(feeRecipient != address(0), "Fee recipient not set in config");

        if (feeToCollect0 > 0) {
            token0.safeTransfer(feeRecipient, feeToCollect0);
        }
        if (feeToCollect1 > 0) {
            token1.safeTransfer(feeRecipient, feeToCollect1);
        }
    }
}