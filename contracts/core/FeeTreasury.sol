// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../config/ProtocolConfig.sol";

/**
 * @title FeeTreasury
 * @dev 專門統一存放協議所有收益（手續費、清算盈餘等）的收益國庫合約。
 * 只有 ProtocolConfig 中被授予 DEFAULT_ADMIN_ROLE (通常是多簽錢包) 的地址才能提取資金。
 */
contract FeeTreasury {
    using SafeERC20 for IERC20;

    // 依賴於我們已經建立好的配置中心來做權限管理
    ProtocolConfig public immutable config;

    // 定義事件
    event FeeWithdrawnERC20(address indexed token, address indexed to, uint256 amount);
    event FeeWithdrawnNative(address indexed to, uint256 amount);

    // 建立一個統一的 Modifier，向 ProtocolConfig 查詢權限
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }

    constructor(address _config) {
        require(_config != address(0), "FeeTreasury: Invalid config address");
        config = ProtocolConfig(_config);
    }

    /**
     * @dev 允許合約接收原生代幣 (ETH/BNB/Matic 等，以防萬一有原生代幣收益)
     */
    receive() external payable {}

    /**
     * @dev 提取指定的 ERC-20 代幣收益，僅限多簽管理員調用
     * @param token ERC20 代幣合約地址(如：底層資產 USDT/USDC 地址)
     * @param to 接收地址(可以提給多簽或是接下來的其他業務合約)
     * @param amount 提取數量
     */
    function withdrawERC20(address token, address to, uint256 amount) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(to != address(0), "FeeTreasury: Invalid recipient address");
        require(amount > 0, "FeeTreasury: Amount must be greater than 0");
        
        IERC20(token).safeTransfer(to, amount);
        
        emit FeeWithdrawnERC20(token, to, amount);
    }

    /**
     * @dev 提取原生代幣收益，僅限多簽管理員調用
     * @param to 接收地址
     * @param amount 提取數量
     */
    function withdrawNative(address payable to, uint256 amount) external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(to != address(0), "FeeTreasury: Invalid recipient address");
        require(amount > 0, "FeeTreasury: Amount must be greater than 0");
        require(address(this).balance >= amount, "FeeTreasury: Insufficient native balance");

        (bool success, ) = to.call{value: amount}("");
        require(success, "FeeTreasury: Native token transfer failed");
        
        emit FeeWithdrawnNative(to, amount);
    }
}
