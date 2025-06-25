// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Price Adapter for Peg Stability Hook
interface IPriceAdapter {
    function exchangeRate() external view returns (uint256 answer, bool isStale);
}
