// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {Test, console} from "lib/forge-std/src/Test.sol";
import {Oraclelib} from "./libraries/Oraclelib.sol";

contract DSCEngine is ReentrancyGuard, Test {
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__PriceFeedAndTokenAddressesMustBeOfSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreakHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFails();
    error DSCEngine__TokenIsNotValid();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorIsNotImproved();
    error DSCEngine__YouOnlyCanRedeemCollateralHalfOfTheSizeOfYourDepositedCollateral();
    error DSCEngine__YouCannotMintMoreThanCollateralAmount();
    error DSCEngine__YouCannotMint();

    using Oraclelib for AggregatorV3Interface;

    mapping(address token => address priceFeed) s_priceFeed;
    mapping(address user => mapping(address token => uint256 amount)) s_collateralDeposited;
    mapping(address user => uint256 amount) s_DSCAmountMinted;

    address[] s_collateralTokens;
    address[] s_mintedTokens;
    DecentralizedStableCoin immutable i_DSC;
    address[] s_tokenAddresses;

    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant PRECISION = 1e18;
    uint256 constant LIQUIDATION_THRESHOLD = 50;
    uint256 constant LIQUIDATION_PRECISION = 100;
    uint256 constant LIQUIDATION_BONUS = 10;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    event CollateralDeposited(address indexed sender, address indexed collateral, uint256 amount);
    event CollateralRedeemed(
        address indexed from, address indexed to, address indexed collateralAddress, uint256 amountCollateral
    );

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            console.log(s_priceFeed[token]);
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    // modifier isValidToken(address token) {
    //     bool valid = false;
    //     for (uint256 i = 0; i < s_tokenAddresses.length; i++) {
    //         if (s_tokenAddresses[i] == token) {
    //             valid = true;
    //             break;
    //         }
    //     }
    //     if (!valid) {
    //         revert DSCEngine__TokenIsNotValid();
    //     }
    //     _;
    // }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__PriceFeedAndTokenAddressesMustBeOfSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeed[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
            s_tokenAddresses.push(tokenAddresses[i]);
        }

        i_DSC = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountToBeMinted
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountToBeMinted);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToBeBurned)
        external
    {
        burnDSC(amountToBeBurned);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function mintDSC(uint256 amountToBeMinted) public moreThanZero(amountToBeMinted) nonReentrant {
        (uint256 totalDscMinted, uint256 collateralAmountInUsd) = _getAccountInformation(msg.sender);

        if (!canMint(totalDscMinted, collateralAmountInUsd)) {
            revert DSCEngine__YouCannotMint();
        }

        s_DSCAmountMinted[msg.sender] += amountToBeMinted;

        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_DSC.mint(msg.sender, amountToBeMinted);
        if (!minted) {
            revert DSCEngine__MintFails();
        }
    }

    function burnDSC(uint256 amountToBeBurned) public moreThanZero(amountToBeBurned) nonReentrant {
        _burnDsc(msg.sender, msg.sender, amountToBeBurned);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function canMint(uint256 totalDscMinted, uint256 collateralAmountInUsd) public pure returns (bool) {
        uint256 currentHealthFactor = _calculateHealthFactor(totalDscMinted, collateralAmountInUsd);
        return currentHealthFactor >= MIN_HEALTH_FACTOR;
    }

    function liquidate(address user, address token, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        isAllowedToken(token)
        nonReentrant
    {
        uint256 startingHealthFactor = _getHealthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 totalAmountOfDebtCovered = getTokenAmountFromUsd(token, debtToCover);
        // console.log(totalAmountOfDebtCovered);
        uint256 bonusCollateral = (totalAmountOfDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeemed = totalAmountOfDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, token, totalCollateralToRedeemed);
        _burnDsc(user, msg.sender, debtToCover);

        uint256 endingHealthFactor = _getHealthFactor(user);
        if (endingHealthFactor == startingHealthFactor) {
            revert DSCEngine__HealthFactorIsNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _getHealthFactor(user);
    }

    function calculateHealthFactor(uint256 amountToBeMinted, uint256 collateralAmount)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(amountToBeMinted, collateralAmount);
    }

    function _getAccountInformation(address user)
        internal
        view
        returns (uint256 totalDscMinted, uint256 collateralAmountInUsd)
    {
        totalDscMinted = s_DSCAmountMinted[user];
        collateralAmountInUsd = getAccountCollateralValueInUsd(user);
    }

    function _getHealthFactor(address user) internal view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralAmountInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralAmountInUsd);
    }

    function _calculateHealthFactor(uint256 amountToBeMinted, uint256 collateralAmount)
        internal
        pure
        returns (uint256)
    {
        if (amountToBeMinted == 0) {
            return type(uint256).max;
        }
        if (amountToBeMinted > collateralAmount) {
            revert DSCEngine__YouCannotMintMoreThanCollateralAmount();
        }
        uint256 collateralAdjustedForThreshold = (collateralAmount * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / amountToBeMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _getHealthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreakHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        internal
    {
        if (amountCollateral > (s_collateralDeposited[from][tokenCollateralAddress]) / 2) {
            revert DSCEngine__YouOnlyCanRedeemCollateralHalfOfTheSizeOfYourDepositedCollateral();
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(address onBehalfOf, address from, uint256 amountToBeBurned) internal {
        s_DSCAmountMinted[onBehalfOf] -= amountToBeBurned;
        bool success = i_DSC.transferFrom(from, address(this), amountToBeBurned);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_DSC.burn(amountToBeBurned);
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            if (amount > 0) {
                totalCollateralValueInUsd += getUsdValue(token, amount);
            }
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view isAllowedToken(token) returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        if (price < 1000) {}

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 amount)
        public
        view
        isAllowedToken(token)
        moreThanZero(amount)
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (amount * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralAmountInUsd)
    {
        (totalDscMinted, collateralAmountInUsd) = _getAccountInformation(user);
        return (totalDscMinted, collateralAmountInUsd);
    }

    function getMintedAmount(address user) public view returns (uint256) {
        return s_DSCAmountMinted[user];
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getLiquidationBonus() public pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getPriceFeed(address token) public view returns (address) {
        return s_priceFeed[token];
    }
}
