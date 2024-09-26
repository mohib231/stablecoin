// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.t.sol";
import {Test, console} from "lib/forge-std/src/Test.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;

    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 public timesMintFunctionCalled;
    uint256 public timesDepositFunctionCalled;

    uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;
    MockV3Aggregator pricefeed;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        address[] memory collateralAddress = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralAddress[0]);
        wbtc = ERC20Mock(collateralAddress[1]);
        pricefeed = MockV3Aggregator(dscEngine.getPriceFeed(address(weth)));
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateralAddress = _validToken(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);
        vm.startPrank(msg.sender);
        collateralAddress.mint(msg.sender, collateralAmount);
        collateralAddress.approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(address(collateralAddress), collateralAmount);
        vm.stopPrank();
        timesDepositFunctionCalled++;
    }

    function mintDsc(uint256 amountToBeMinted) public {
        if (timesDepositFunctionCalled == 0) {
            return;
        }
        if (amountToBeMinted == 0) {
            return;
        }
        vm.startPrank(msg.sender);

        (uint256 totalDscMinted, uint256 collateralAmountInUsd) = dscEngine.getAccountInformation(msg.sender);
        uint256 expectedhealthFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralAmountInUsd);
        int256 maxDscToMint = int256((collateralAmountInUsd / 2) - totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amountToBeMinted = bound(amountToBeMinted, 0, uint256(maxDscToMint));
        if (amountToBeMinted == 0) {
            return;
        }
        if (expectedhealthFactor < dscEngine.MIN_HEALTH_FACTOR()) {
            return;
        } else {
            dscEngine.mintDSC(amountToBeMinted);
        }
        vm.stopPrank();
        timesMintFunctionCalled++;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        if (timesMintFunctionCalled == 0) {
            return;
        } else {
            ERC20Mock collateralAddress = _validToken(collateralSeed);

            uint256 maxCollateralToRedeem = dscEngine.getMintedAmount(msg.sender);
            collateralAmount = bound(collateralAmount, 0, (maxCollateralToRedeem));

            (uint256 totalDscMinted, uint256 collateralAmountInUsd) = dscEngine.getAccountInformation(msg.sender);
            uint256 expectedhealthFactor = dscEngine.calculateHealthFactor(totalDscMinted, collateralAmountInUsd);

            if (expectedhealthFactor < dscEngine.MIN_HEALTH_FACTOR()) {
                return;
            }
            if (collateralAmount == 0) {
                return;
            }
            dscEngine.redeemCollateral(address(collateralAddress), collateralAmount);
        }
    }

    function pricefeedChanger(uint96 changedPrice) public {
        pricefeed.updateAnswer(int256(uint256(changedPrice)));
    }

    function _validToken(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
 

}
