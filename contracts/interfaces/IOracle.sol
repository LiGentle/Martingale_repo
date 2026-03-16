// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Chainlink 标准接口
interface IOracle {
    function decimals() external view returns (uint8);
    
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,//作用：用于标识这次价格更新是第几轮
            int256 answer,//含义：实际的价格数据（最重要的返回值）；精度：由 decimals() 函数指定；
            uint256 startedAt,//含义：这轮价格聚合开始的时间戳
            uint256 updatedAt,//含义：价格最后更新的时间戳（非常重要）
            uint80 answeredInRound//含义：价格实际被回答/确认的轮次ID
        );
}