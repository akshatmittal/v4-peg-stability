// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseOverrideFee.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {SqrtPriceLibrary} from "./libraries/SqrtPriceLibrary.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";

/// @title Peg Stability Hook
/// @notice Peg Stability Hook for pools pairing ETH and ETH derivatives.
contract PegStabilityHook is BaseOverrideFee, Ownable {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    struct PriceFeedDetails {
        IPriceFeed priceFeed; // Price feed for the peg, Chainlink or RedStone
        uint256 staleDuration; // Duration after which the price feed is considered stale
        uint256 priceFactor; // Multiplier to convert feed data to pool price format
    }

    struct FeeDetails {
        uint24 minFee; // Minimum fee for the peg stability hook
        uint24 maxFee; // Maximum fee for the peg stability hook
        uint24 defaultFee; // Fee applied when the price feed is stale
    }

    PriceFeedDetails public priceFeedData; // Price feed details for the peg
    FeeDetails public feeData;

    address public immutable targetToken; // Target token for the peg, i.e. weETH/wstETH/ezETH

    // Errors
    error PegStabilityHook__InvalidSetup(uint256 code);
    error PegStabilityHook__InvalidInitialize();

    constructor(
        IPoolManager _poolManager,
        address _targetToken,
        PriceFeedDetails memory _priceFeedData,
        FeeDetails memory _feeData
    ) BaseOverrideFee(_poolManager) Ownable(msg.sender) {
        require(address(_targetToken) != address(0), PegStabilityHook__InvalidSetup(0));
        require(address(_priceFeedData.priceFeed) != address(0), PegStabilityHook__InvalidSetup(1));
        require(_priceFeedData.staleDuration != 0, PegStabilityHook__InvalidSetup(2));
        require(_priceFeedData.priceFactor != 0, PegStabilityHook__InvalidSetup(3));

        targetToken = _targetToken;
        priceFeedData = _priceFeedData;

        setFeeData(_feeData);
    }

    function setFeeData(
        FeeDetails memory _feeData
    ) public onlyOwner {
        require(_feeData.minFee <= _feeData.maxFee, PegStabilityHook__InvalidSetup(4));
        require(_feeData.defaultFee <= _feeData.maxFee, PegStabilityHook__InvalidSetup(5));
        require(_feeData.maxFee <= 1_0000, PegStabilityHook__InvalidSetup(6)); // Max fee is 1%

        feeData = _feeData;
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
            return feeData.minFee;
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (, int256 answer,, uint256 updatedAt,) = priceFeedData.priceFeed.latestRoundData();

        if (updatedAt + priceFeedData.staleDuration < block.timestamp) {
            return feeData.defaultFee;
        }

        uint160 referencePriceX96 =
            SqrtPriceLibrary.exchangeRateToSqrtPriceX96(uint256(answer) * priceFeedData.priceFactor);

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
