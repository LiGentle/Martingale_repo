// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MathUtils
 * @dev 提供高精度的小数运算，特别是基于 WAD (1e18) 进位的乘除法。
 * 由于 Solidity ^0.8.0 已经内置了溢出检查，故移除了手动 safe加减乘除 以节省 Gas。
 */
library MathUtils {
    uint256 internal constant PRECISION_UNIT = 1e18;

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
}
