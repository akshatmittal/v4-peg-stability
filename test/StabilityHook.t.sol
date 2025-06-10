// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2, Vm} from "forge-std/Test.sol";
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
import {SwapFeeEventAsserter} from "hookmate/test/utils/SwapFeeEventAsserter.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {Deployers} from "./utils/Deployers.sol";
import {SqrtPriceLibrary} from "../src/libraries/SqrtPriceLibrary.sol";

import {PegStabilityHook, IPriceFeed, MIN_FEE, MAX_FEE} from "../src/PegStabilityHook.sol";

contract StabilityHookTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SwapFeeEventAsserter for Vm;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;

    PegStabilityHook hook;
    IPriceFeed priceFeed;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    uint160 initialPrice;

    function setUp() public {
        vm.createSelectFork("unichain", 18624000);

        // Deploys all required artifacts.
        deployArtifacts();

        currency0 = Currency.wrap(address(0)); // ETH
        currency1 = Currency.wrap(0x7DCC39B4d1C53CB31e1aBc0e358b43987FEF80f7); // weETH on Unichain

        priceFeed = IPriceFeed(0xBf3bA2b090188B40eF83145Be0e9F30C6ca63689); // RedStone price feed for weETH

        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        initialPrice = SqrtPriceLibrary.exchangeRateToSqrtPriceX96(uint256(answer) * 1e10);

        console2.log("weETH price:", answer);
        console2.log("weETH updated at:", updatedAt);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(poolManager, priceFeed, Currency.unwrap(currency1), 1 days);
        deployCodeTo("PegStabilityHook.sol:PegStabilityHook", constructorArgs, flags);
        hook = PegStabilityHook(flags);

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

    function testFuzz_SwapFee_HighFee(
        bool zeroForOne
    ) public {
        vm.recordLogs();
        BalanceDelta ref = swapRouter.swap{value: 0.1e18}(
            -int256(0.1e18),
            0, // No limit on the output amount
            zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        vm.assertSwapFee(recordedLogs, MIN_FEE);

        // move the pool price to off peg
        swapRouter.swap{value: 1000e18}(
            -int256(1000e18),
            0, // Don't care.
            zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );

        // move the pool price away from peg
        vm.recordLogs();
        BalanceDelta highFeeSwap = swapRouter.swap{value: 0.1e18}(
            -int256(0.1e18),
            0, // No limit on the output amount
            zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );
        recordedLogs = vm.getRecordedLogs();
        vm.assertSwapFee(recordedLogs, zeroForOne ? MIN_FEE : MAX_FEE);

        // Output of the second swap is much less
        if (zeroForOne) {
            assertLt(highFeeSwap.amount1() + int128(0.001e18), ref.amount1());
        } else {
            assertLt(highFeeSwap.amount0() + int128(0.001e18), ref.amount0());
        }
    }

    function testFuzz_SwapFee_LowFee(
        bool zeroForOne
    ) public {
        // move the pool price to off peg
        swapRouter.swap{value: 1000e18}(
            -int256(1000e18),
            0, // Don't care.
            !zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );

        // move the pool price away from peg
        vm.recordLogs();
        BalanceDelta highFeeSwap = swapRouter.swap{value: 0.1e18}(
            -int256(0.1e18),
            0, // No limit on the output amount
            !zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        uint24 higherFee = SwapFeeEventAsserter.getSwapFeeFromEvent(recordedLogs);

        // swap towards the peg
        vm.recordLogs();
        BalanceDelta lowFeeSwap = swapRouter.swap{value: 0.1e18}(
            -int256(0.1e18),
            0, // No limit on the output amount
            zeroForOne,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );
        recordedLogs = vm.getRecordedLogs();
        uint24 lowerFee = SwapFeeEventAsserter.getSwapFeeFromEvent(recordedLogs);

        if (zeroForOne) {
            assertGt(higherFee, lowerFee);
            assertEq(lowerFee, MIN_FEE); // minFee
        } else {
            assertEq(lowerFee, MIN_FEE); // minFee
            assertEq(higherFee, MIN_FEE); // minFee
        }

        // Output of the second swap is much higher
        if (zeroForOne) {
            assertGt(lowFeeSwap.amount1(), highFeeSwap.amount1());
        } else {
            assertGt(lowFeeSwap.amount0(), highFeeSwap.amount0());
        }
    }

    function testFuzz_Swap_LinearFee(
        uint256 amount
    ) public {
        // Approximately where the fee is within range.
        vm.assume(0.5e18 < amount && amount <= 40e18);

        swapRouter.swap{value: amount}(
            -int256(amount),
            0, // No limit on the output amount
            false,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );

        (uint160 poolSqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint256 absPercentageDiffWad =
            SqrtPriceLibrary.absPercentageDifferenceWad(uint160(poolSqrtPriceX96), initialPrice);
        uint24 expectedFee = uint24(absPercentageDiffWad / 1e12);

        // move the pool price away from peg
        vm.recordLogs();
        swapRouter.swap{value: 0.1e18}(
            -int256(0.1e18),
            0, // No limit on the output amount
            false,
            poolKey,
            Constants.ZERO_BYTES,
            address(this),
            block.timestamp + 3600
        );
        Vm.Log[] memory recordedLogs = vm.getRecordedLogs();
        uint24 swapFee = SwapFeeEventAsserter.getSwapFeeFromEvent(recordedLogs);
        assertEq(swapFee, expectedFee);
    }

    receive() external payable {}
}
