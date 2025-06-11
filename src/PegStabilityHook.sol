// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {SqrtPriceLibrary} from "./libraries/SqrtPriceLibrary.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

// Fee is tracked as pips, i.e. 3000 = 0.3%
uint24 constant MIN_FEE = 100; // Min fee; 0.01%
uint24 constant MAX_FEE = 1_0000; // Max fee: 1%
uint24 constant STALE_FEE = 500; // Stale fee: 0.05%

/// @title Peg Stability Hook
/// @notice Peg Stability Hook for pools pairing ETH and ETH derivatives.
contract PegStabilityHook is BaseOverrideFee {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    IPriceFeed public immutable priceFeed; // Price feed for the peg, Chainlink or RedStone
    uint256 public immutable staleDuration; // Duration after which the price feed is considered stale

    address public immutable targetToken; // Target token for the peg, i.e. weETH/wstETH/ezETH

    // Errors
    error PegStabilityHook__InvalidSetup();
    error PegStabilityHook__InvalidInitialize();

    constructor(
        IPoolManager _poolManager,
        IPriceFeed _priceFeed,
        address _targetToken,
        uint256 _staleDuration
    ) BaseOverrideFee(_poolManager) {
        require(address(_priceFeed) != address(0) && _targetToken != address(0), PegStabilityHook__InvalidSetup());

        priceFeed = _priceFeed;
        targetToken = _targetToken;
        staleDuration = _staleDuration;
    }

    /**
     * @dev Validate pool initialization
     * @dev Check that pair is as initialized
     */
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal virtual override returns (bytes4) {
        require(key.fee.isDynamicFee(), PegStabilityHook__InvalidInitialize());
        require(
            key.currency0 == Currency.wrap(address(0)) && key.currency1 == Currency.wrap(targetToken),
            PegStabilityHook__InvalidInitialize()
        );

        return this.afterInitialize.selector;
    }

    function _getFee(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal virtual override returns (uint24) {
        // Trading towards the target token. (buying weETH with ETH)
        if (params.zeroForOne) {
            return MIN_FEE;
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();

        if (updatedAt + staleDuration < block.timestamp) {
            return STALE_FEE;
        }

        uint160 referencePriceX96 = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(uint256(answer) * 1e10);

        // Price is less than the reference price. Incentivize trading.
        if (sqrtPriceX96 < referencePriceX96) {
            return MIN_FEE;
        }

        // Percentage difference between the pool price and the reference price
        uint256 absPercentageDiff =
            SqrtPriceLibrary.absPercentageDifferenceWad(uint160(sqrtPriceX96), referencePriceX96);

        // 1e18 precision to pips
        uint24 fee = uint24(absPercentageDiff / 1e12);

        if (fee < MIN_FEE) {
            fee = MIN_FEE;
        }
        if (fee > MAX_FEE) {
            fee = MAX_FEE;
        }

        return fee;
    }
}
