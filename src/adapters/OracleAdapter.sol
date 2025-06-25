// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IPriceAdapter } from "../interfaces/IPriceAdapter.sol";
import { IPriceFeed } from "../interfaces/IPriceFeed.sol";

contract OracleAdapter is IPriceAdapter {
    struct PriceFeedDetails {
        IPriceFeed priceFeed; // Price feed for the peg, Chainlink or RedStone
        uint256 staleDuration; // Duration after which the price feed is considered stale
        uint256 priceFactor; // Multiplier to convert feed data to pool price format
    }

    PriceFeedDetails public priceFeedData; // Price feed details for the peg

    error OracleAdapter__InvalidSetup(uint256 code);

    constructor(IPriceFeed _priceFeed, uint256 _staleDuration, uint256 _priceFactor) {
        require(address(_priceFeed) != address(0), OracleAdapter__InvalidSetup(0));
        require(_staleDuration > 0, OracleAdapter__InvalidSetup(1));
        require(_priceFactor > 0, OracleAdapter__InvalidSetup(2));

        priceFeedData = PriceFeedDetails({
            priceFeed: _priceFeed, // Chainlink or RedStone supported
            staleDuration: _staleDuration,
            priceFactor: _priceFactor
        });
    }

    function exchangeRate() external view override returns (uint256 answer, bool isStale) {
        (, int256 trueAnswer,, uint256 updatedAt,) = priceFeedData.priceFeed.latestRoundData();

        answer = uint256(trueAnswer) * priceFeedData.priceFactor;
        isStale = updatedAt + priceFeedData.staleDuration < block.timestamp;
    }
}
