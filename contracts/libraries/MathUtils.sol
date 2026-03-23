// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MathUtils
 * @dev 提供高精度的小数运算，特别是基于 WAD (1e18) 进位的乘除法。
 * 由于 Solidity ^0.8.0 已经内置了溢出检查，故移除了手动 safe加减乘除 以节省 Gas。
 */
library MathUtils {
    uint256 internal constant PRECISION_UNIT = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 1e4;


    /**
     * @dev 返回两个相中的最小值
     */
    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x <= y ? x : y;
    }

    /**
     * @dev 返回两个相中的最大值
     */
    function max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }

    /**
     * @dev WAD 乘法 (基于 1e18 的乘法)
     * e.g. wmul(2e18, 2e18) = 4e18
     */
    function wmul(uint256 x, uint256 y) internal pure returns (uint256) {
        // (x * y) / 1e18
        return (x * y) / PRECISION_UNIT;
    }

    /**
     * @dev WAD 除法 (基于 1e18 的除法)
     * e.g. wdiv(4e18, 2e18) = 2e18
     */
    function wdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        // (x * 1e18) / y
        return (x * PRECISION_UNIT) / y;
    }

    /**
     * @dev BPS 乘法 (基于精度1e4的乘法)
     * e.g. bmul(2e18, 2e4) = 4e18
     */
    function bmul(uint256 x, uint256 y) internal pure returns (uint256) {
        // (x * y) / 1e18
        return (x * y) / BPS_DENOMINATOR;
    }

    /**
     * @dev 计算两个值的百分比偏差 (基点)
     * @param currentValue 当前值
     * @param newValue 新值
     * @return deviationBps 偏差基点 (100 = 1%)
     * e.g. calcDeviationBps(100e18, 105e18) = 500 (5% deviation)
     */
    function calcDeviationBps(uint256 currentValue, uint256 newValue) internal pure returns (uint256 deviationBps) {
        if (currentValue == 0) {
            // 如果当前值为0，任何非零新值都被认为是100%偏差
            return newValue > 0 ? 10_000 : 0;
        }
        uint256 diff;
        if (newValue >= currentValue) {
            diff = newValue - currentValue;
        } else {
            diff = currentValue - newValue;
        }
        // (diff / currentValue) * 10_000
        deviationBps = (diff * 10_000) / currentValue;
    }
}
