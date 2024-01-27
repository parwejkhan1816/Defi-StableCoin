// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    error DSCEngine_moreThanZero();
    error TokenAddressesAndPriceFeedAddressesMustBeOFSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_transferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk() ; 
    error DSCEngine__HealthFactorNotImproved() ;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10 ;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCMintted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    event CollateralDepoisted(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_moreThanZero();
        }
        _;
    }

    modifier isTokenAllowed(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert TokenAddressesAndPriceFeedAddressesMustBeOFSameLength();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDSCToMint
    ) public {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSCToMint);
    }

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral) public
        moreThanZero(amountCollateral)
        isTokenAllowed(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDepoisted(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine_transferFailed();
        }
    }

    function redeemCollateralForDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external 
    {
        _burnDSC(amountDscToBurn,msg.sender,msg.sender) ;
        redeemCollateral(tokenCollateralAddress,amountCollateral) ; 
    }

    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public 
    moreThanZero(amountCollateral) 
    nonReentrant 
    {
        _redeemCollateral(tokenCollateralAddress,amountCollateral,msg.sender,msg.sender) ;
        _revertIfHealthFactorBroken(msg.sender) ; 
    }

    function mintDSC(uint256 amountDSCMint) public moreThanZero(amountDSCMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCMint;
        _revertIfHealthFactorBroken(msg.sender);
        bool Minted = i_dsc.mint(msg.sender, amountDSCMint);
        if (!Minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function buruDSC(uint256 amount) external moreThanZero(amount) {
        _burnDSC(amount,msg.sender,msg.sender) ; 
        _revertIfHealthFactorBroken(msg.sender) ; 
    }

    function liquidate(address collateral,address user,uint256 debtToCover) external 
    moreThanZero(debtToCover)
    nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user) ;

        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine__HealthFactorOk() ;
        }
        uint256 tokenAmountFromDebtToCovered = getTokenAmountFromUsd(collateral,debtToCover) ;
        uint256 bonusCollateral = (tokenAmountFromDebtToCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION ; 
        uint256 totalCollateralToRedeem = tokenAmountFromDebtToCovered + bonusCollateral ;  
        _redeemCollateral(collateral,totalCollateralToRedeem,user,msg.sender) ;
        _burnDSC(debtToCover,user,msg.sender) ;
        uint256 endingUserHealthFactor = _healthFactor(user) ; 

        if(endingUserHealthFactor <= startingUserHealthFactor)
        {
            revert DSCEngine__HealthFactorNotImproved() ; 
        }
        _revertIfHealthFactorBroken(user) ;
    }

    function getHealthFactor(address user) external view returns(uint256){
        return _healthFactor(user) ;
    }

    function _burnDSC(uint256 amountDscToBurn,address onBehalfOf,address dscFrom) private
    {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn ;
        bool success   = i_dsc.transferFrom(dscFrom,address(this),amountDscToBurn) ; 
        if(!success)
        {
            revert DSCEngine_transferFailed() ; 
        }
        i_dsc.burn(amountDscToBurn) ;    
    }

    function _redeemCollateral(address tokenCollateralAddress,uint256 amountCollateral, address from,address to) private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral ; 
        emit CollateralRedeemed(from,to,tokenCollateralAddress,amountCollateral) ; 
        bool  success = IERC20(tokenCollateralAddress).transfer(to,amountCollateral) ; 
        if(!success)
        {
            revert DSCEngine_transferFailed() ; 
        }
    }
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUSD)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValuedInUSD) = _getAccountInformation(user);
        uint256 collateralAdjustedThreshold = ((collateralValuedInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION);
        return (collateralAdjustedThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(userHealthFactor);
        }
    }


    function getTokenAmountFromUsd(address token,uint256 usdAmountInWei) private view returns(uint256)
    {

       AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]) ;
       (,int256 price,,,) = priceFeed.latestRoundData() ;

       return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION)) ; 
    }
    function getAccountCollateralValue(address user) public view returns (uint256 tokenCollateralValueInUSD) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            tokenCollateralValueInUSD += getUsdValue(token, amount);
        }
        return tokenCollateralValueInUSD;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user) public view returns(uint256 totalDscMinted,uint256 collateralValueInUsd){
        (totalDscMinted , collateralValueInUsd) = _getAccountInformation(user) ; 
    } 
    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

}
