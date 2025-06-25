// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BaseOverrideFee } from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";

import { IPoolManager, SwapParams, IHooks } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import { SqrtPriceLibrary } from "./libraries/SqrtPriceLibrary.sol";
import { IPriceAdapter } from "./interfaces/IPriceAdapter.sol";

/// @title Peg Stability Hook
/// @notice Peg Stability Hook for pools pairing like-kind assets with ETH.
contract PegStabilityHook is BaseOverrideFee {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    struct FeeDetails {
        uint24 minFee; // Minimum fee for the peg stability hook
        uint24 maxFee; // Maximum fee for the peg stability hook
        uint24 defaultFee; // Fee applied when the price feed is stale
    }

    struct PoolData {
        IPriceAdapter priceAdapter;
        address feeController;
        FeeDetails feeData;
    }

    mapping(PoolId => PoolData) public poolSettings;

    // Errors
    error PegStabilityHook__InvalidSetup(uint256 code);
    error PegStabilityHook__InvalidOptions(uint256 code);

    constructor(
        IPoolManager _poolManager
    ) BaseOverrideFee(_poolManager) { }

    function createPoolWithAdapter(
        address targetToken,
        int24 tickSpacing,
        IPriceAdapter priceAdapter,
        FeeDetails calldata feeData,
        address feeController
    ) external returns (PoolKey memory poolKey, PoolId poolId, uint160 initialPrice) {
        require(address(priceAdapter) != address(0), PegStabilityHook__InvalidSetup(0));
        require(feeController != address(0), PegStabilityHook__InvalidSetup(1));

        (uint256 answer, bool isStale) = priceAdapter.exchangeRate();
        require(!isStale, PegStabilityHook__InvalidSetup(2));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(targetToken),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        poolId = poolKey.toId();
        initialPrice = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(answer);

        poolSettings[poolId] = PoolData({
            priceAdapter: priceAdapter,
            feeController: feeController,
            feeData: feeData // Can be modified by feeController
         });

        setFeeData(poolId, feeData); // Validates fee data

        poolManager.initialize(poolKey, initialPrice);
    }

    function setFeeData(PoolId poolId, FeeDetails memory _feeData) public {
        PoolData storage pool = poolSettings[poolId];

        require(msg.sender == pool.feeController, PegStabilityHook__InvalidOptions(1)); // Already enforces that the pool exists.
        require(_feeData.minFee <= _feeData.maxFee, PegStabilityHook__InvalidOptions(2));
        require(_feeData.defaultFee <= _feeData.maxFee, PegStabilityHook__InvalidOptions(3));
        require(_feeData.maxFee <= 1_0000, PegStabilityHook__InvalidOptions(4)); // Max fee is 1%

        pool.feeData = _feeData;
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
        PoolData storage pool = poolSettings[key.toId()];

        require(address(pool.priceAdapter) != address(0), PegStabilityHook__InvalidSetup(100));

        return this.afterInitialize.selector;
    }

    function _getFee(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal virtual override returns (uint24) {
        PoolData storage pool = poolSettings[key.toId()];
        FeeDetails storage feeData = pool.feeData;

        // Trading towards the target token. (buying weETH with ETH)
        if (params.zeroForOne) {
            return feeData.minFee;
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (uint256 answer, bool isStale) = pool.priceAdapter.exchangeRate();

        if (isStale) {
            return feeData.defaultFee;
        }

        uint160 referencePriceX96 = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(answer);

        // Price is less than the reference price. Incentivize trading.
        if (sqrtPriceX96 < referencePriceX96) {
            return feeData.minFee;
        }

        // Percentage difference between the pool price and the reference price
        uint256 absPercentageDiff = SqrtPriceLibrary.absPercentageDifferenceWad(sqrtPriceX96, referencePriceX96);

        // 1e18 precision to pips
        uint24 fee = uint24(absPercentageDiff / 1e12);

        if (fee < feeData.minFee) {
            return feeData.minFee;
        }
        if (fee > feeData.maxFee) {
            return feeData.maxFee;
        }

        return fee;
    }
}
