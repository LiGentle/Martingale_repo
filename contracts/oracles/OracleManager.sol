// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../config/ProtocolConfig.sol";
import "../interfaces/IOracleManager.sol";


contract OracleManager is IOracleManager, ReentrancyGuard {
    // ================= State Variables =================

    /// @notice Chainlink price feed interface
    AggregatorV3Interface internal priceFeed;

    /// @notice Current validated price (18 decimals)
    uint256 public currentPrice;

    /// @notice Pending price waiting for delay period (18 decimals)
    uint256 public pendingPrice;

    /// @notice Timestamp when pending price was set
    uint256 public pendingPriceTimestamp;

    /// @notice Emergency stop flag - when true, all operations are blocked
    bool public emergencyStop;

    /// @notice Protocol configuration contract (immutable)
    ProtocolConfig public immutable config;

    // ================= Events =================

    /// @notice Emitted when prices are updated
    /// @param newCurrentPrice The new current price (previous pending price)
    /// @param newPendingPrice The new pending price (from Chainlink)
    /// @param timestamp Block timestamp when update occurred
    event PriceUpdated(uint256 newCurrentPrice, uint256 newPendingPrice, uint256 timestamp);

    /// @notice Emitted when emergency stop status changes
    /// @param stopped Whether the oracle is now in emergency stop mode
    event EmergencyStopSet(bool stopped);


    // ================= Modifiers =================

    /// @notice Modifier to restrict function execution when oracle is in emergency stop mode
    /// @dev Reverts if the emergency stop flag is set to true
    /// @custom:error OracleInEmergencyStop when emergencyStop is true
    modifier notEmergencyStopped() {
        require(!emergencyStop, "Oracle in emergency stop mode");
        _;
    }

    /// @notice Modifier to restrict function execution to callers with specific role
    /// @param role The role identifier from ProtocolConfig
    /// @dev Uses ProtocolConfig's role-based access control system
    /// @custom:error AccessControlUnauthorized when caller lacks the required role
    modifier onlyRole(bytes32 role) {
        require(config.hasRole(role, msg.sender), "Caller missing required role");
        _;
    }

    // ================= Constructor =================

    /// @notice Constructor to initialize the ChainlinkOracle contract
    /// @param _priceFeedAddress Address of the Chainlink price feed aggregator
    /// @param _config Address of the ProtocolConfig contract
    /// @custom:error ZeroAddressConfig if _config is zero address
    /// @custom:error ZeroAddressPriceFeed if _priceFeedAddress is zero address
    constructor( address _config, address _priceFeedAddress) {
        require(_config != address(0), "Zero address config");
        require(_priceFeedAddress != address(0), "Zero address price feed");
        config = ProtocolConfig(_config);
        priceFeed = AggregatorV3Interface(_priceFeedAddress);
        pendingPriceTimestamp = block.timestamp;
        emit PriceUpdated(0, 0, block.timestamp);
    }

    // ================= Price Management Functions =================

    /// @notice Updates the oracle price from Chainlink price feed
    /// @dev Only callable by accounts with ORACLE_ROLE. Applies delay mechanism to prevent flash attacks.
    /// @custom:error PendingPriceDelayNotPassed if delay hasn't elapsed since last price update
    /// @custom:error InvalidPriceData if price data is invalid or stale
    function updatePrice() external onlyRole(config.ORACLE_ROLE()) notEmergencyStopped nonReentrant {
        // Check if we can update the pending price based on delay mechanism
        (uint256 delay,) = config.oracleParams();
        bool canUpdate = pendingPrice == 0 || block.timestamp >= pendingPriceTimestamp + delay;
        require(canUpdate, "Pending price delay not passed");

        // Fetch latest price data from Chainlink
        (
        uint80 roundID,
        int256 rawPrice,
        /*uint256 startedAt*/,
        uint256 timestamp,
        uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Validate price data - multiple checks for security
        require(rawPrice > 0, "Invalid price data: price <= 0");
        require(timestamp > 0, "Invalid price data: round not complete");
        require(answeredInRound == roundID, "Invalid price data: stale price");

        // Update prices: current becomes previous pending, pending becomes new data
        uint256 previousPrice = currentPrice;
        currentPrice = pendingPrice;
        pendingPrice = convert8to18(uint256(rawPrice));
        pendingPriceTimestamp = block.timestamp;

        emit PriceUpdated(previousPrice, currentPrice, pendingPriceTimestamp);
    }

    // ================= View Functions =================

    /// @notice Gets the latest validated price view from the oracle
    /// @dev Returns price, timestamp, and validity flag based on max price age configuration
    /// @return price The current validated price (18 decimals)
    /// @return timestamp Current block timestamp
    /// @return isValid Whether the price is considered valid (not too old and > 0)
    function getLatestPriceView() notEmergencyStopped external view returns (uint256 price, uint256 timestamp, bool isValid) {
        (, uint256 maxPriceAge) = config.oracleParams();
        price = currentPrice;
        timestamp = block.timestamp;
        isValid = (block.timestamp <= pendingPriceTimestamp + maxPriceAge && currentPrice > 0);
    }

    /// @notice Gets the pending price that will become active after the delay period
    /// @return price The pending price (18 decimals)
    /// @return timestamp Timestamp when the pending price was set
    function getPendingPrice() external view returns (uint256 price, uint256 timestamp) {
        price = pendingPrice;
        timestamp = pendingPriceTimestamp;
    }

    // ================= Utility Functions =================

    /// @notice Converts price from 8 decimals to 18 decimals
    /// @param price8Decimals Price in 8 decimals (Chainlink standard)
    /// @return Price in 18 decimals (protocol standard)
    function convert8to18(uint256 price8Decimals) public pure returns (uint256) {
        return price8Decimals * 1e10;
    }

    // ================= Emergency Management =================

    /// @notice Activates emergency stop mode, blocking all price updates and queries
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    function emergencyStopOracle() external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(!emergencyStop, "Already in emergency stop mode");
        emergencyStop = true;
        emit EmergencyStopSet(true);
    }

    /// @notice Deactivates emergency stop mode, resuming normal oracle operations
    /// @dev Only callable by accounts with DEFAULT_ADMIN_ROLE
    function emergencyRestartOracle() external onlyRole(config.DEFAULT_ADMIN_ROLE()) {
        require(emergencyStop, "Not in emergency stop mode");
        emergencyStop = false;
        emit EmergencyStopSet(false);
    }

}