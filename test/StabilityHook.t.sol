// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";
import {SqrtPriceLibrary} from "../src/libraries/SqrtPriceLibrary.sol";

import {EtherFiStabilityHook, IPriceFeed} from "../src/EtherFiStabilityHook.sol";

contract StabilityHookTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    EtherFiStabilityHook hook;
    IPriceFeed priceFeed;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        vm.createSelectFork("unichain", 18624000);

        // Deploys all required artifacts.
        deployArtifacts();

        currency0 = Currency.wrap(address(0)); // ETH
        currency1 = Currency.wrap(0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7); // weETH on Unichain

        priceFeed = IPriceFeed(0xBf3bA2b090188B40eF83145Be0e9F30C6ca63689); // RedStone price feed for weETH

        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        uint160 initialPrice = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(uint256(answer) * 1e10);

        console2.log("weETH price:", answer);
        console2.log("weETH updated at:", updatedAt);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager, priceFeed, Currency.unwrap(currency1)); // Add all the necessary constructor arguments from the hook
        deployCodeTo("EtherFiStabilityHook.sol:EtherFiStabilityHook", constructorArgs, flags);
        hook = EtherFiStabilityHook(flags);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolManager.initialize(poolKey, initialPrice);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 10_000e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            initialPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(currency1), address(swapRouter), type(uint160).max, type(uint48).max);

        vm.deal(address(this), amount0Expected + 1); // Ensure we have enough ETH to mint the position
        deal(Currency.unwrap(currency1), address(this), amount1Expected + 1); // Ensure we have enough weETH to mint the position

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp + 3600,
            Constants.ZERO_BYTES
        );

        vm.deal(address(this), 10_000e18); // Ensure we have enough ETH to swap
        deal(Currency.unwrap(currency1), address(this), 10_000e18); // Ensure we have enough weETH to swap
    }

    function testCounterHooks() public {
        assertEq(uint256(1), uint256(1));
    }

    function testFuzz_Swap(bool zeroForOne, bool exactIn) public {
        int256 amountSpecified = exactIn ? -int256(1e18) : int256(1e18);
        uint256 msgValue = zeroForOne ? 2e18 : 0;

        BalanceDelta result = swapRouter.swap{value: msgValue}(
            amountSpecified,
            exactIn ? 0 : type(uint256).max, // No limit on the output amount
            zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );

        if (zeroForOne) {
            if (exactIn) {
                assertEq(int256(result.amount0()), amountSpecified);
                assertGt(int256(result.amount1()), 0);
            } else {
                assertEq(int256(result.amount1()), amountSpecified);
                assertLt(int256(result.amount0()), amountSpecified);
            }
        } else {
            if (exactIn) {
                assertEq(int256(result.amount1()), amountSpecified);
                assertGt(int256(result.amount0()), 0);
            } else {
                assertEq(int256(result.amount0()), amountSpecified);
                assertLt(int256(result.amount1()), amountSpecified);
            }
        }
    }

    receive() external payable {}
}
