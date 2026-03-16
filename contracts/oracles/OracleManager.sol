// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../config/ProtocolConfig.sol";
import "../interfaces/IOracle.sol";

/**
 * @title OracleManager
 * @dev 統一管理協議中所有資產的預言機(Price Feed)。
 * 透過 ProtocolConfig 的全局權限來控制。
 */
contract OracleManager {
    ProtocolConfig public immutable config;

    // 資產地址 => PriceFeed 合約地址
    mapping(address => IOracle) public priceFeeds;
    // 資產地址 => 預言機精度
    mapping(address => uint8) public priceFeedDecimals;

    event PriceFeedUpdated(address indexed asset, address indexed oldFeed, address indexed newFeed, uint8 decimals);

    modifier onlyAdmin() {
        require(config.hasRole(config.DEFAULT_ADMIN_ROLE(), msg.sender), "OracleManager: Caller is not admin");
        _;
    }

    constructor(address _config) {
        require(_config != address(0), "OracleManager: Invalid config address");
        config = ProtocolConfig(_config);
    }

    /**
     * @dev 設定或更新指定資產的預言機地址
     * @param asset 底層資產代幣地址 (e.g. USDC, USDT)
     * @param feedAddr Chainlink Price Feed (IOracle) 地址
     */
    function setPriceFeed(address asset, address feedAddr) external onlyAdmin {
        require(asset != address(0), "OracleManager: Invalid asset address");
        require(feedAddr != address(0), "OracleManager: Invalid feed address");

        address oldFeed = address(priceFeeds[asset]);
        require(feedAddr != oldFeed, "OracleManager: Same price feed address");

        IOracle newFeed = IOracle(feedAddr);
        uint8 decimals = newFeed.decimals();

        priceFeeds[asset] = newFeed;
        priceFeedDecimals[asset] = decimals;

        emit PriceFeedUpdated(asset, oldFeed, feedAddr, decimals);
    }

    /**
     * @dev 獲取給定資產的最新有效價格 (統一回傳 18 位精度)
     * @param asset 資產地址
     * @return priceInWei 最新價格（18位小数）
     * @return timeInSecond 最新价格更新时间
     * @return isValid 数据是否有效
     */
    function getLatestPriceView(address asset) external view returns (
        uint256 priceInWei,
        uint256 timeInSecond,
        bool isValid
    ) {
        IOracle feed = priceFeeds[asset];
        require(address(feed) != address(0), "OracleManager: No price feed found");

        try feed.latestRoundData() returns (
            uint80 /* roundId */,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 /* answeredInRound */
        ) {
            if (answer <= 0) {
                return (0, updatedAt, false);
            }
            if (block.timestamp - updatedAt > config.maxPriceAge()) {
                return (0, updatedAt, false);
            }

            uint256 p = uint256(answer);
            uint8 decimals = priceFeedDecimals[asset];

            // 將價格標準化為 18 位精度
            if (decimals < 18) {
                p = p * (10 ** (18 - decimals));
            } else if (decimals > 18) {
                p = p / (10 ** (decimals - 18));
            }

            return (p, updatedAt, true);
        } catch {
            return (0, 0, false);
        }
    }
}
