# Peg Stability Hook

Hook to be used with Uniswap v4, for creating a peg stability mechanism for a token where the current price is available via an oracle (Chainlink or RedStone).

The hook is designed to pair ETH with an ETH derivative like weETH/wstETH/ezETH.

1. The hook charges a `MIN_FEE` if the swap is:
   - Buying the target token (e.g., weETH) with ETH.
   - Moving the price towards the target price.
2. The hook charges a linear fee up to `MAX_FEE` if:
   - Moving the price away from the target price, based on the percentage difference from the target price.
3. The hook charges an average of `MIN_FEE` and `MAX_FEE` if:
   - The price feed for the asset is stale.
