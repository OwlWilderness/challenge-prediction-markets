//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

//buidlguidl challenge https://speedrunethereum.com/challenge/prediction-markets
//quantumtekh.eth

import { PredictionMarketToken } from "./PredictionMarketToken.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract PredictionMarket is Ownable {
    /////////////////
    /// Errors //////
    /////////////////

    error PredictionMarket__MustProvideETHForInitialLiquidity();
    error PredictionMarket__InvalidProbability();
    error PredictionMarket__PredictionAlreadyReported();
    error PredictionMarket__OnlyOracleCanReport();
    error PredictionMarket__OwnerCannotCall();
    error PredictionMarket__PredictionNotReported();
    error PredictionMarket__InsufficientWinningTokens();
    error PredictionMarket__AmountMustBeGreaterThanZero();
    error PredictionMarket__MustSendExactETHAmount();
    error PredictionMarket__InsufficientTokenReserve(Outcome _outcome, uint256 _amountToken);
    error PredictionMarket__TokenTransferFailed();
    error PredictionMarket__ETHTransferFailed();
    error PredictionMarket__InsufficientBalance(uint256 _tradingAmount, uint256 _userBalance);
    error PredictionMarket__InsufficientAllowance(uint256 _tradingAmount, uint256 _allowance);
    error PredictionMarket__InsufficientLiquidity();
    error PredictionMarket__InvalidPercentageToLock();

    //////////////////////////
    /// State Variables //////
    //////////////////////////
    

    enum Outcome {
        YES,
        NO
    }

    uint256 private constant PRECISION = 1e18;

    /// Checkpoint 2 ///
    uint256 public s_ethCollateral; //the total ETH backing the tokens
    uint256 public s_lpTradingRevenue; //tracks the fees earned from users buying/selling tokens — the LP’s reward
  
    address public immutable i_oracle; //the address that will later report the outcome
    string public s_question; //the actual prediction being asked
    uint256 public immutable i_initialTokenValue; //the ETH value a winning token pays out 
    uint8 public immutable i_initialYesProbability; //how likely “Yes” is at the start 
    uint8 public immutable i_percentageLocked; //used in probability + pricing logic
    
    /// Checkpoint 3 ///
    PredictionMarketToken public immutable i_yesToken;
    PredictionMarketToken public immutable i_noToken;

    /// Checkpoint 5 ///
    PredictionMarketToken public s_winningToken;
    bool public s_isReported;

    /////////////////////////
    /// Events //////
    /////////////////////////

    event TokensPurchased(address indexed buyer, Outcome outcome, uint256 amount, uint256 ethAmount);
    event TokensSold(address indexed seller, Outcome outcome, uint256 amount, uint256 ethAmount);
    event WinningTokensRedeemed(address indexed redeemer, uint256 amount, uint256 ethAmount);
    event MarketReported(address indexed oracle, Outcome winningOutcome, address winningToken);
    event MarketResolved(address indexed resolver, uint256 totalEthToSend);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 tokensAmount);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 tokensAmount);

    /////////////////
    /// Modifiers ///
    /////////////////

    /// Checkpoint 5 ///

    //verify not reported
    modifier predictionNotReported() {
        if(s_isReported){
            revert PredictionMarket__PredictionAlreadyReported();
        }
        _;
    }

    //ensure only oracle can call this method (report)
    modifier onlyOracle(){
        if(msg.sender != i_oracle){
            revert PredictionMarket__OnlyOracleCanReport();
        }
        _;
    }

    /// Checkpoint 6 ///
    //verify reported
    modifier predictionReported() {
        if(!s_isReported){
            revert PredictionMarket__PredictionNotReported();
        }
        _;
    }

    /// Checkpoint 8 ///
    modifier amtGreaterThanZero(uint256 _amount){
        if(_amount == 0){
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier verifyNotOwner(){
        if(msg.sender == owner()){
            revert PredictionMarket__OwnerCannotCall();
        }
        _;
    }
    //////////////////
    ////Constructor///
    //////////////////

    constructor(
        address _liquidityProvider,
        address _oracle,
        string memory _question,
        uint256 _initialTokenValue,
        uint8 _initialYesProbability,
        uint8 _percentageToLock
    ) payable Ownable(_liquidityProvider) {
        /// Checkpoint 2 ////
        //require initial liquidity
        if(msg.value == 0){
            revert PredictionMarket__MustProvideETHForInitialLiquidity();
        }

        //require init yes probabiliy between 0 and 100
        if(_initialYesProbability == 0 || _initialYesProbability >= 100){
            revert PredictionMarket__InvalidProbability();
        }

        //require percentage to lock 100 or less
        if(_percentageToLock == 0 || _percentageToLock >= 100){
            revert PredictionMarket__InvalidPercentageToLock();
        }

        i_oracle = _oracle;
        s_question = _question;
        i_initialTokenValue = _initialTokenValue;
        i_initialYesProbability = _initialYesProbability;
        i_percentageLocked = _percentageToLock;

        s_ethCollateral = msg.value;

        /// Checkpoint 3 ////
        //calculate inital token amount;
        uint256 initialTokenAmount;
        if(_initialTokenValue == 0){
            initialTokenAmount = type(uint256).max;
        } else {
            initialTokenAmount = (msg.value * PRECISION) / _initialTokenValue ;
        }

        //create yes and no contracts
        ////note***************************************************
        //// was referencing i_ imutable variables at first
        //// did not work - needed to reference passed in arguments
        ////*******************************************************

        i_yesToken = new PredictionMarketToken("YesToken","YES",_liquidityProvider,initialTokenAmount);
        i_noToken = new PredictionMarketToken("NoToken","NO",_liquidityProvider,initialTokenAmount);

        //get locked token amounts 
        //// note************************************************************************************************
        //// originally tried: initialTokenAmount * (_initialYesProbability/100)  * (_percentageToLock/100) * 2
        //// this returned 0
        ////******************************************************************************************************
        uint256 yesLocked = (initialTokenAmount * _initialYesProbability  * _percentageToLock * 2) / 10000;
        uint256 noLocked = (initialTokenAmount * (100 - _initialYesProbability) * _percentageToLock * 2) / 10000;

        //transfer locked tokens
        bool okYesXfr = i_yesToken.transfer(msg.sender, yesLocked);
        bool okNoXfr = i_noToken.transfer(msg.sender, noLocked);
        if(!okYesXfr || !okNoXfr){
            revert PredictionMarket__TokenTransferFailed();
        }
    }

    /////////////////
    /// Functions ///
    /////////////////

    /**
     * @notice Add liquidity to the prediction market and mint tokens
     * @dev Only the owner can add liquidity and only if the prediction is not reported
     */
    function addLiquidity() external payable onlyOwner predictionNotReported {
        //// Checkpoint 4 ////
        //require non zero liquidity
        if(msg.value == 0){
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }

        s_ethCollateral += msg.value;

        //calculate additional token amount and mint yes and no tokens
        uint256 additionalTokenAmount = (msg.value * PRECISION) / i_initialTokenValue;
        i_yesToken.mint(address(this), additionalTokenAmount);
        i_noToken.mint(address(this), additionalTokenAmount);
        
        emit LiquidityAdded(msg.sender, msg.value, additionalTokenAmount);

    }

    /**
     * @notice Remove liquidity from the prediction market and burn respective tokens, if you remove liquidity before prediction ends you got no share of lpReserve
     * @dev Only the owner can remove liquidity and only if the prediction is not reported
     * @param _ethToWithdraw Amount of ETH to withdraw from liquidity pool
     */
    function removeLiquidity(uint256 _ethToWithdraw) external onlyOwner predictionNotReported {
        //// Checkpoint 4 ////
        //require non zero withdraw amount
        if(_ethToWithdraw == 0){
            revert PredictionMarket__AmountMustBeGreaterThanZero();
        }

        //require withdrawl amount > collateral
        if(_ethToWithdraw > s_ethCollateral){
            revert PredictionMarket__InsufficientTokenReserve(Outcome.YES,_ethToWithdraw);
        }
        s_ethCollateral -= _ethToWithdraw;

        //burn tokens       
        uint256 burnlTokenAmount = (_ethToWithdraw * PRECISION) / i_initialTokenValue;

        if(i_yesToken.balanceOf(address(this)) > i_yesToken.totalSupply()) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.YES, burnlTokenAmount);
        }

        if(i_noToken.balanceOf(address(this)) > i_noToken.totalSupply()) {
            revert PredictionMarket__InsufficientTokenReserve(Outcome.NO, burnlTokenAmount);
        }

        i_yesToken.burn(address(this), burnlTokenAmount);
        i_noToken.burn(address(this), burnlTokenAmount);

        //xfer withdrawn collateral to sender
        (bool success, ) = msg.sender.call{value: _ethToWithdraw}("");
        if(!success){
            revert PredictionMarket__ETHTransferFailed();
        }

        emit LiquidityRemoved(msg.sender, _ethToWithdraw, burnlTokenAmount);
    }

    /**
     * @notice Report the winning outcome for the prediction
     * @dev Only the oracle can report the winning outcome and only if the prediction is not reported
     * @param _winningOutcome The winning outcome (YES or NO)
     */
    function report(Outcome _winningOutcome) external onlyOracle predictionNotReported {
        //// Checkpoint 5 ////
        if(_winningOutcome == Outcome.YES){
            s_winningToken = i_yesToken;
        } else {
            s_winningToken = i_noToken;
        }
        s_isReported = true;

        emit MarketReported(msg.sender, _winningOutcome, address(s_winningToken));
    }
    /**
     * @notice Owner of contract can redeem winning tokens held by the contract after prediction is resolved and get ETH from the contract including LP revenue and collateral back
     * @dev Only callable by the owner and only if the prediction is resolved
     * @return ethRedeemed The amount of ETH redeemed
     */
    function resolveMarketAndWithdraw() external onlyOwner predictionReported returns (uint256 ethRedeemed) {
        /// Checkpoint 6 ////
        uint256 winningTokenBalance = s_winningToken.balanceOf(address(this));
        if(winningTokenBalance == 0){
            revert PredictionMarket__InsufficientWinningTokens();
        }

        //calculate winning token  value
        uint256 winningTokenValue = (winningTokenBalance * i_initialTokenValue) / PRECISION ;
        if(winningTokenValue > s_ethCollateral){
            ethRedeemed = s_ethCollateral;
        } else {
            ethRedeemed = winningTokenValue;
        }
        s_ethCollateral -= ethRedeemed;

        //caclulate tokal eth to send
        uint256 totalEthToSend = ethRedeemed + s_lpTradingRevenue;

        //burn winning tokens
        s_winningToken.burn(address(this), winningTokenBalance);

        //reset state variables 
        s_ethCollateral = 0;
        s_lpTradingRevenue = 0;

        //xfer eth to sender
        (bool success, ) = msg.sender.call{value: totalEthToSend}("");
        if(!success){
            revert PredictionMarket__ETHTransferFailed();
        }
        emit MarketResolved(msg.sender, totalEthToSend);

        return ethRedeemed;
    }

    /**
     * @notice Buy prediction outcome tokens with ETH, need to call priceInETH function first to get right amount of tokens to buy
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _amountTokenToBuy Amount of tokens to purchase
     */
    function buyTokensWithETH(Outcome _outcome, uint256 _amountTokenToBuy) external predictionNotReported amtGreaterThanZero(_amountTokenToBuy) verifyNotOwner payable {
        /// Checkpoint 8 ////

        //validate sent eth equals required eth
        uint256 ethPrice = getBuyPriceInEth(_outcome, _amountTokenToBuy);
        if(ethPrice != msg.value){
            revert PredictionMarket__MustSendExactETHAmount();
        }

        //get token reserves
        (uint256 yesReserves, uint256 noReserves) = _getCurrentReserves(Outcome.YES);

        //validate enough tokens to sell
        uint256 checkReserves = _outcome == Outcome.YES ? yesReserves : noReserves;
        if(_amountTokenToBuy > checkReserves){
            revert PredictionMarket__InsufficientTokenReserve(_outcome, _amountTokenToBuy);
        }

        //update trading revenue
        s_lpTradingRevenue += ethPrice;

        //xfr tokens
        bool okXfr = _outcome == Outcome.YES ? i_yesToken.transfer(msg.sender, _amountTokenToBuy) : i_noToken.transfer(msg.sender, _amountTokenToBuy);

        //validate xfer
        if(!okXfr){
            revert PredictionMarket__TokenTransferFailed();
        }
        
        emit TokensPurchased(msg.sender, _outcome, _amountTokenToBuy, ethPrice);

    }

    /**
     * @notice Sell prediction outcome tokens for ETH, need to call priceInETH function first to get right amount of tokens to buy
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     */
    function sellTokensForEth(Outcome _outcome, uint256 _tradingAmount) external predictionNotReported amtGreaterThanZero(_tradingAmount) verifyNotOwner  {
        /// Checkpoint 8 ////
        //verify user balance
        uint256 userBalance = _outcome == Outcome.YES ? i_yesToken.balanceOf(msg.sender) : i_noToken.balanceOf(msg.sender) ;
        
        if(_tradingAmount > userBalance){              
            revert PredictionMarket__InsufficientBalance(_tradingAmount, userBalance);
        }

        //get sell price and validate amount
        uint256 ethPrice = getSellPriceInEth(_outcome, _tradingAmount);

        uint256 allowanceAmt = _outcome == Outcome.YES ? i_yesToken.allowance(msg.sender, address(this)) : i_noToken.allowance(msg.sender, address(this));
        if(_tradingAmount > allowanceAmt){
            revert PredictionMarket__InsufficientAllowance(_tradingAmount, allowanceAmt);
        }

        //xfr tokens
        bool okXfr = _outcome == Outcome.YES ? i_yesToken.transferFrom(msg.sender, address(this), _tradingAmount) : i_noToken.transfer(address(this), _tradingAmount);

        //validate xfer
        if(!okXfr){
            revert PredictionMarket__TokenTransferFailed();
        }

        s_lpTradingRevenue -= ethPrice;

        //xfer eth to sender
        (bool success, ) = msg.sender.call{value: ethPrice}("");
        if(!success){
            revert PredictionMarket__ETHTransferFailed();
        }

        emit TokensSold(msg.sender, _outcome, _tradingAmount, ethPrice);
    }

    /**
     * @notice Redeem winning tokens for ETH after prediction is resolved, winning tokens are burned and user receives ETH
     * @dev Only if the prediction is resolved
     * @param _amount The amount of winning tokens to redeem
     */
    function redeemWinningTokens(uint256 _amount) external {
        /// Checkpoint 9 ////
    }

    /**
     * @notice Calculate the total ETH price for buying tokens
     * @param _outcome The possible outcome (YES or NO) to buy tokens for
     * @param _tradingAmount The amount of tokens to buy
     * @return The total ETH price
     */
    function getBuyPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
        return _calculatePriceInEth(_outcome, _tradingAmount, false);
    }

    /**
     * @notice Calculate the total ETH price for selling tokens
     * @param _outcome The possible outcome (YES or NO) to sell tokens for
     * @param _tradingAmount The amount of tokens to sell
     * @return The total ETH price
     */
    function getSellPriceInEth(Outcome _outcome, uint256 _tradingAmount) public view returns (uint256) {
        /// Checkpoint 7 ////
        return _calculatePriceInEth(_outcome, _tradingAmount, true);    
    }

    /////////////////////////
    /// Helper Functions ///
    ////////////////////////

    /**
     * @dev Internal helper to calculate ETH price for both buying and selling
     * @param _outcome The possible outcome (YES or NO)
     * @param _tradingAmount The amount of tokens
     * @param _isSelling Whether this is a sell calculation
     */
    function _calculatePriceInEth(
        Outcome _outcome,
        uint256 _tradingAmount,
        bool _isSelling
    ) private view returns (uint256) {
        /// Checkpoint 7 ////

        //get reserves
        (uint256 token1Reserves, uint256 token2Reserves) = _getCurrentReserves(_outcome);
        //validate
        if(!_isSelling && _tradingAmount > token1Reserves){
            revert PredictionMarket__InsufficientLiquidity();
        }

        uint256 supply = i_yesToken.totalSupply();
        
        //probabilty before
        uint256 before1Sold = supply - token1Reserves;
        uint256 before2Sold = supply - token2Reserves;
        uint256 totalBefore = before1Sold + before2Sold;
        uint256 probabilityBefore = _calculateProbability(before1Sold, totalBefore);

        //probability after
        uint256 afterReserve = _isSelling ? token1Reserves + _tradingAmount : token1Reserves - _tradingAmount;
        uint256 after1Sold = supply - afterReserve;
        uint256 totalAfter = _isSelling ? totalBefore - _tradingAmount : totalBefore + _tradingAmount;
        uint256 probabilityAfter = _calculateProbability(after1Sold, totalAfter);

        //calculate avg
        uint256 probabilityAvg = (probabilityBefore + probabilityAfter) / 2;

        //aclulate price
        uint256 price = (i_initialTokenValue * probabilityAvg * _tradingAmount) / (PRECISION * PRECISION);

        return price;

    }

    /**
     * @dev Internal helper to get the current reserves of the tokens
     * @param _outcome The possible outcome (YES or NO)
     * @return The current reserves of the tokens in order starting with _outcome
     */
    function _getCurrentReserves(Outcome _outcome) private view returns (uint256, uint256) {
        /// Checkpoint 7 ////
        uint256 yesReserves = i_yesToken.balanceOf(address(this));
        uint256 noReserves = i_noToken.balanceOf(address(this));
        if(_outcome == Outcome.YES){
            return (yesReserves, noReserves);
        } else {
            return (noReserves, yesReserves);
        }
    }

    /**
     * @dev Internal helper to calculate the probability of the tokens
     * @param tokensSold The number of tokens sold
     * @param totalSold The total number of tokens sold
     * @return The probability of the tokens
     */
    function _calculateProbability(uint256 tokensSold, uint256 totalSold) private pure returns (uint256) {
        /// Checkpoint 7 ////
        return (tokensSold * PRECISION / totalSold) ;
    }

    /////////////////////////
    /// Getter Functions ///
    ////////////////////////

    /**
     * @notice Get the prediction details
     */
    function getPrediction()
        external
        view
        returns (
            string memory question,
            string memory outcome1,
            string memory outcome2,
            address oracle,
            uint256 initialTokenValue,
            uint256 yesTokenReserve,
            uint256 noTokenReserve,
            bool isReported,
            address yesToken,
            address noToken,
            address winningToken,
            uint256 ethCollateral,
            uint256 lpTradingRevenue,
            address predictionMarketOwner,
            uint256 initialProbability,
            uint256 percentageLocked
        )
    {
        /// Checkpoint 3 ////
        oracle = i_oracle;
        initialTokenValue = i_initialTokenValue;
        percentageLocked = i_percentageLocked;
        initialProbability = i_initialYesProbability;
        question = s_question;
        ethCollateral = s_ethCollateral;
        lpTradingRevenue = s_lpTradingRevenue;
        predictionMarketOwner = owner();
        yesToken = address(i_yesToken);
        noToken = address(i_noToken);
        outcome1 = i_yesToken.name();
        outcome2 = i_noToken.name();
        yesTokenReserve = i_yesToken.balanceOf(address(this));
        noTokenReserve = i_noToken.balanceOf(address(this));
        /// Checkpoint 5 ////
        isReported = s_isReported;
        winningToken = address(s_winningToken);
    }
}
