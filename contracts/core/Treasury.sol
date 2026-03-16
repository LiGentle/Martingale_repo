// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../config/ProtocolConfig.sol";

//存放抵押資產的Treasury合約只要這樣定義就足夠嗎，如何防止攻擊？
//作爲僅僅存放用戶資產的Treasury合約是否有什麽標準？
//我在TrancheVault中執行burn時,會調用withdraw,所以這裏是不是不能是onlyOwner，而是onlyTrancheVault合約
//項目需要定期存入資產，在該合約中幫我定義一個函數，只有某個地址可以存入資產

contract Treasury {
    using SafeERC20 for IERC20;

    ProtocolConfig public immutable config;
    IERC20 public immutable underlyingToken;

    // 定義事件，方便鏈下追蹤收益注入與管理員變更
    event YieldDeposited(address indexed depositor, uint256 amount);

    // 建立一個統一的 Modifier，向 ProtocolConfig 查詢權限
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }

    constructor(
        address _config,
        address _underlyingToken
    ) {
        require(_underlyingToken != address(0), "Invalid token address");
        underlyingToken = IERC20(_underlyingToken);
        config = ProtocolConfig(_config);
    }

    // 仅允许 Vault (通过 role 控制) 拨付资金
    // burn時, 每次都需要多簽非常不合理，所以我们将 withdraw 权限授权给 TrancheVault
    // 未来如果清算合约需要直接操作资产，只需在 ProtocolConfig 里给清算合约发 VAULT_ROLE 即可
    function withdraw(address to, uint256 amount) external onlyRole(config.VAULT_ROLE()) {
        underlyingToken.safeTransfer(to, amount);
    }

    //該函數風險不大，使用onlyRole的意義更多的在於防止有人污染數據
    /**
     * @notice 允許項目方存入底层資產作為收益
     * @param amount 存入的數量
     */
    function depositYield(uint256 amount) external onlyRole(config.DEPOSITOR_ROLE()) {
        require(amount > 0, "Amount must be greater than zero");
        
        // 使用 safeTransferFrom 將代幣從呼叫者(項目方管理員)轉入 Treasury
        underlyingToken.safeTransferFrom(msg.sender, address(this), amount);
        
        // 觸發事件
        emit YieldDeposited(msg.sender, amount);
    }

    // 查看余额
    function getBalance() external view returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    // used for fund migration when we upgrade the Treasury contract, only admin can call this function
    function migrateFunds(address newTreasury, uint256 amount) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(newTreasury != address(0), "Invalid new treasury");
        underlyingToken.safeTransfer(newTreasury, amount);
    }
}
