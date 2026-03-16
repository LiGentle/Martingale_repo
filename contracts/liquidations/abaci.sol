// SPDX-License-Identifier: AGPL-3.0-or-later

/// abaci.sol -- price decrease functions for auctions

// Copyright (C) 2020-2022 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.20;
import "@openzeppelin/contracts/access/AccessControl.sol";

interface Abacus {
    // 1st arg: initial price               [wad]
    // 2nd arg: seconds since auction start [seconds]
    // returns: current auction price       [wad]
    function price(uint256, uint256) external view returns (uint256);
}

contract LinearDecrease is AccessControl, Abacus {


    // --- 权限管理 ---
    bytes32 public constant CALLER_ROLE = keccak256("CALLER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    function grantCallerRole(address account) onlyRole(ADMIN_ROLE) public {
        grantRole(CALLER_ROLE, account);
        emit CallerAccessGranted(account);
    }  
    function revokeCallerRole(address account) onlyRole(ADMIN_ROLE) public {
        revokeRole(CALLER_ROLE, account);
        emit CallerAccessRevoked(account);
    }
    function grantAdminRole(address account) onlyRole(ADMIN_ROLE) public {
        grantRole(ADMIN_ROLE, account);
        emit AdminAccessGranted(account);
    }
    function revokeAdminRole(address account) onlyRole(ADMIN_ROLE) public {
        revokeRole(ADMIN_ROLE, account);
        emit AdminAccessRevoked(account);
    }

    // --- 事件 ---
    event AdminAccessGranted(address indexed user);
    event CallerAccessGranted(address indexed user);    
    event AdminAccessRevoked(address indexed user);
    event CallerAccessRevoked(address indexed user);

    // --- Data ---
    uint256 public tau;  // Seconds after auction start when the price reaches zero [seconds]

    // --- Init ---
    constructor(uint256 _tau, address auctionAddr) {
        // 设置角色 (权限管理)
        tau=_tau;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        grantCallerRole(auctionAddr);
        emit AdminAccessGranted(msg.sender);
    }

    // --- Administration ---
    function file( uint256 data) external onlyRole(CALLER_ROLE) {
        tau = data;
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / WAD;
    }

    // Price calculation when price is decreased linearly in proportion to time:
    // tau: The number of seconds after the start of the auction where the price will hit 0
    // top: Initial price [wad]
    // dur: current seconds since the start of the auction
    //
    // Returns y = top * ((tau - dur) / tau) [wad]
    function price(uint256 top, uint256 dur) override external view returns (uint256) {
        if (dur >= tau) return 0;
        return wmul(top, mul(tau - dur, WAD) / tau);
    }
}

