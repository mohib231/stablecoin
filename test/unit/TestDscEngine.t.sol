// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.t.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDsc.sol";

contract TestDscEngine is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address weth;
    address wbtc;
    address wethPriceFeed;
    address wbtcPriceFeed;
    address public USER = makeAddr("user");
    address public USER2 = makeAddr("user2");
    uint256 constant AMOUNT_COLLATERAL = 10 ether;

    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (wethPriceFeed, wbtcPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_RevertsIfTheTokenAddressLengthIsNotSameAsPriceFeedAddressLength() public {
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);
        priceFeedAddresses.push(wbtcPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__PriceFeedAndTokenAddressesMustBeOfSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function test_GetValueInUsdIsCorrectOrNot() public view {
        uint256 amount = 15e18;
        uint256 expectedAmount = 30000e18;
        uint256 valueInUsd = dscEngine.getUsdValue(weth, amount);
        assertEq(valueInUsd, expectedAmount);
    }

    function test_GetTokenAmountFromUsd() public view {
        uint256 amount = 2000e18;
        uint256 expectedAmount = 1e18;
        uint256 tokenAmount = dscEngine.getTokenAmountFromUsd(weth, amount);
        assertEq(tokenAmount, expectedAmount);
    }

    function test_DepositCollateralWithZeroAddress() public {
        uint256 amount = 1000;
        vm.expectRevert();
        dscEngine.depositCollateral(address(0), amount);
    }

    function test_DepositCollateralWithZeroAmount() public {
        uint256 amount = 0;
        vm.expectRevert();
        dscEngine.depositCollateral(weth, amount);
    }

    function test_depositCollateralAndMintDsc() public {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 50 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDSC(weth, amountCollateral, amountToBeMinted);
        uint256 userDscBalance = IERC20(address(dsc)).balanceOf(USER);
        assertEq(amountToBeMinted, userDscBalance);

        uint256 userMintedAmount = dscEngine.getMintedAmount(USER);
        assertEq(amountToBeMinted, userMintedAmount);
        vm.stopPrank();
    }

    function test_DepositCollateralRevertsWithUnApprovedCollaterals() public {
        ERC20Mock newToken = new ERC20Mock("newToken", "newToken", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(newToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_getAccountCollateralValueInUsd() public {
        vm.prank(USER);
        uint256 totalCollateralValueInUsd = dscEngine.getAccountCollateralValueInUsd(USER);
        console.log(totalCollateralValueInUsd);
    }

    function test_CanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralAmountInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, collateralAmountInUsd);
        //20000,000,000,000,000,000,000
        //10,000,000,000,000,000,000
        assertEq(AMOUNT_COLLATERAL, expectedCollateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
    }

    function test_mintDSCSuccessful() public {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 50 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(weth, amountCollateral);

        dscEngine.mintDSC(amountToBeMinted);
        // uint256 amountInUsd = dscEngine.getUsdValue(address(weth), amountToBeMinted);

        uint256 userDscBalance = IERC20(address(dsc)).balanceOf(USER);
        assertEq(amountToBeMinted, userDscBalance);

        uint256 userMintedAmount = dscEngine.getMintedAmount(USER);
        assertEq(amountToBeMinted, userMintedAmount);
        vm.stopPrank();
    }

    function test_mintDSCFailsDueToHealthFactor() public {
        uint256 amountCollateral = 99 ether;
        uint256 amountToBeMinted = 50 ether;
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wethPriceFeed);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 amountToMint =
            ((uint256(price) * dscEngine.ADDITIONAL_FEED_PRECISION()) * (amountToBeMinted)) / dscEngine.PRECISION();

        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, amountCollateral));
        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(weth, amountCollateral);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreakHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    function test_redeemCollateralRevertIfTheRedeemAmountIsGreaterThanTheHalfOfTheSIzeOfDepositedCollateral() public {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 60 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(weth, amountCollateral);
        dscEngine.mintDSC(amountCollateral);
        vm.expectRevert();
        dscEngine.redeemCollateral(address(weth), amountToBeMinted);
        vm.stopPrank();
    }

    function test_redeemCollateralSuccessful() public {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 50 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(weth, amountCollateral);
        dscEngine.mintDSC(amountCollateral);
        dscEngine.redeemCollateral(address(weth), amountToBeMinted / 2);
        vm.stopPrank();
    }

    function test_redeemCollateralAndBurnDsc() public {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 50 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDSC(weth, amountCollateral, amountToBeMinted);
        dsc.approve(address(dscEngine), amountToBeMinted);
        dscEngine.redeemCollateralForDSC(weth, amountToBeMinted, amountToBeMinted);
        vm.stopPrank();
    }

    function test_BurnDSC() public {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 50 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, amountCollateral);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(weth, amountCollateral);
        dscEngine.mintDSC(amountCollateral);
        dscEngine.redeemCollateral(address(weth), amountToBeMinted);

        dsc.approve(address(dscEngine), amountToBeMinted);
        dscEngine.burnDSC(amountToBeMinted);
        vm.stopPrank();
    }

    function test_healthFactorBreaksWhenMintingAmountIsZero() public view {
        uint256 amountCollateral = 100 ether;
        uint256 amountToBeMinted = 0;

        uint256 expectedResult = dscEngine.calculateHealthFactor(amountToBeMinted, amountCollateral);
        assertEq(expectedResult, type(uint256).max);
    }
}
