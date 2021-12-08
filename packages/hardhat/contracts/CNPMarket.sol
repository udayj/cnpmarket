//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IBentoBoxMinimal.sol";
import "./IERC20.sol";
import {ISuperfluid, ISuperToken, ISuperApp, ISuperAgreement, SuperAppDefinitions} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperAppBase} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";
import {IConstantFlowAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";
import {IInstantDistributionAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IInstantDistributionAgreementV1.sol";
import {ISETH} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/tokens/ISETH.sol";

interface ISuperTokenNative {
    function upgradeByETH() external payable;
    function balanceOf(address) external payable;
}



contract CNPMarket is ChainlinkClient, Ownable{
    
    using Chainlink for Chainlink.Request;
    event NewDeal(uint dealId, address initiator, uint256 val, uint upOrDown, uint timer);
    event DealJoined(uint dealId, address joiner);
    event DealCompleted(uint dealId);
    //address payable _cEtherContract=payable(0x41B5844f4680a8C38fBb695b7F9CFd1F64474a72);
    address public oracle_alarm=0xc8D925525CA8759812d0c299B90247917d4d4b7C;
    bytes32 public jobId_alarm="6c7a0cf966184f6b935e6dc1c8d26d3e";
    address public oracle_price=0xc8D925525CA8759812d0c299B90247917d4d4b7C;
    bytes32 public jobId_price="bbf0badad29d49dc887504bacfbb905b";
    uint256 private fee=0.01*10**18;
    IBentoBoxMinimal bentoContract;
    ISETH maticx;
    IInstantDistributionAgreementV1 ida;
    ISuperfluid host;

    mapping (bytes32 => uint) requestIdTimerToDealId;
    mapping (bytes32 => uint) requestIdPriceToDealId;
    mapping (uint => bool) poolIdExists;
    Deal[] public deals;
    
    struct Deal {
        address payable initiator;
        address payable joiner1;
        address payable joiner2;
        uint256[] dealAmount;
        bool[] winners;
        uint[] upOrDown;
        uint256 val;
        uint timer;
        uint state;
        uint256 result;
        uint256 groupId;
        uint256 amountBento;
        uint256 shareBento;
        uint256 interest;
    }
    
    constructor () {
        setPublicChainlinkToken();
        bentoContract = IBentoBoxMinimal(address(0xF5BCE5077908a1b7370B9ae04AdC565EBd643966));
        bentoContract.registerProtocol();
        maticx=ISETH(0x96B82B65ACF7072eFEb00502F45757F254c2a0D4);
        ida=IInstantDistributionAgreementV1(0x804348D4960a61f2d5F9ce9103027A3E849E09b8);
        host=ISuperfluid(0xEB796bdb90fFA0f28255275e16936D25d3418603);
    }

    function setBentoAddress(address _address) public {
        bentoContract = IBentoBoxMinimal(_address);
        bentoContract.registerProtocol();
    }



    function deposit(uint256 amt) public returns(uint256,uint256) {
        
        address matic = address(0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889);
        IERC20(matic).approve(address(0xF5BCE5077908a1b7370B9ae04AdC565EBd643966),amt);
        (uint256 amountOut,uint256 shareOut1) = bentoContract.deposit(
            matic,
            address(this),
            address(this),
            amt,
            0
            );
        return (amountOut,shareOut1);
    }

    function depositToBento(uint256 _dealId, uint256 amt) public {

        getWMatic(amt);
        uint256 amountOut=0;
        uint256 shareOut=0;
        (amountOut, shareOut) = deposit(amt);

        
        deals[_dealId].shareBento = shareOut;
    }


    function withdrawBento(uint256 shares) public returns(uint256 amountOut, uint256 shareOut1) {

        address matic = address(0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889);
        (uint256 amountOut,uint256 shareOut1) = bentoContract.withdraw(
            matic,
            address(this),
            address(this),
            0,
            shares    
            );
        
        return (amountOut,shareOut1);

    }

     function withdrawFromBento(uint256 _id) public {
       Deal storage deal = deals[_id];
        uint256 shares = deal.shareBento;
        uint256 amountOut=0;
        uint256 shareOut=0;
        uint256 interest=0;
        (amountOut, shareOut)=withdrawBento(shares);
        uint256 totalAmount = deal.dealAmount[0] + deal.dealAmount[1] + deal.dealAmount[2];
        if(amountOut > totalAmount){
            interest = amountOut - totalAmount;
        }
        else {
            //doing this just for demonstration since the time being set was 5 minutes and in this time almost no interest was being
            //earned, it wont be necessary in a production version
            interest = 100;
        }
        deal.amountBento = amountOut;
        deal.shareBento=0; //all shares are withdrawn for this particular payment(deposit)
        deal.interest = interest;
        //currentInterestEarned+=interest;
        convertToMatic(amountOut);

    }

    function setOracleAlarm(address _add) public  onlyOwner() {
        oracle_alarm=_add;
    }
    
    function setJobIdAlarm(bytes32 _job) public onlyOwner() {
        jobId_alarm=_job;    
    }
    
    function setOraclePrice(address _add) public onlyOwner() {
        oracle_price=_add;
    }
    function setJobIdPrice(bytes32 _job) public onlyOwner() {
        jobId_price=_job;
    }
    
    
    
    function getDealAmount(uint _dealId) public view returns(uint256[] memory) {
        return deals[_dealId].dealAmount;
    }
    
    function getDealInitiator(uint _dealId) public view returns(address) {
        return deals[_dealId].initiator;
    }
    function getDealJoiner(uint _dealId) public view returns(address,address) {
        return (deals[_dealId].joiner1,deals[_dealId].joiner2);
    }


    function upgrade(uint amount) public payable{

        maticx.upgradeByETH{value:amount}();

    }

     function create(uint _groupId) public returns(bytes memory){

        bytes memory data = abi.encode(0);

        bytes memory newCtx=host.callAgreement(
            ida,
            abi.encodeWithSelector(
                ida.createIndex.selector,
                maticx,
                _groupId,
                new bytes(0)
            ),
            data
        );
       
       return newCtx;
    }

    function update(address subscriber,uint128 units, uint _groupId) public returns(bytes memory){

        bytes memory data = abi.encode(0);
        bytes memory newCtx= host.callAgreement (
            ida,
            abi.encodeWithSelector(
                ida.updateSubscription.selector,
                maticx,
                _groupId,
                subscriber,
                units,
                new bytes(0)
            ),
            data
        );
        
        
        return newCtx;
    }

    function dist(uint _groupId,uint amount) public returns(bytes memory){

        bytes memory data = abi.encode(0);
        bytes memory newCtx = host.callAgreement (
            ida,
            abi.encodeWithSelector(
                ida.distribute.selector,
                maticx,
                _groupId,
                amount,
                new bytes(0)
            ),
            data
        );
        
        return newCtx;
    }

    function claim(address subscriber, uint _groupId) public returns(bytes memory) {

        bytes memory data = abi.encode(0);
        bytes memory newCtx = host.callAgreement (
            ida,
            abi.encodeWithSelector(
                ida.claim.selector,
                maticx,
                address(this),
                _groupId,
                subscriber,
                new bytes(0)
            ),
            data
        );
        
        return newCtx;
    }
    /*
    @param _val - value for the bet, both parties will need to place bet for same amount
    @param _upOrDown - 1 indicates initiator is betting price will be >= _val, any other value means <
    @param _timer - number of seconds to wait after deal is joined to verify result of bet
    @return dealId - to be used by joiner to join this bet
    */
    function initiateDeal(uint256 _val, uint _upOrDown, uint _timer, uint _groupId) external payable returns(uint256) {
        
        require(msg.value>0,"Need to stake non-zero deal amount");
        uint[] memory dealAmount = new uint[](3);
        dealAmount[0]=msg.value;
        bool[] memory winners = new bool[](3);
        uint[] memory upOrDown = new uint[](3);
        upOrDown[0]=_upOrDown;
        deals.push(Deal(payable(msg.sender),payable(0), payable(0),dealAmount, winners,upOrDown,_val,_timer,0,0,_groupId,0,0,0));
        uint dealId=deals.length-1;
        emit NewDeal(dealId, msg.sender, _val, _upOrDown,_timer);
        if(!poolIdExists[_groupId]) {
          poolIdExists[_groupId]=true;
          create(_groupId);
        }    
        return dealId;
        
    }
    

    
    function getDealWinners(uint _dealId) public view returns(bool[] memory) {
        
        return deals[_dealId].winners;
    }
    
    
    
    function getDealState(uint _dealId) public view returns(uint) {
        return deals[_dealId].state;
    }
    
    function getDealResult(uint _dealId) public view returns(uint256) {
        return deals[_dealId].result;
    }
    /*
    @param _dealId - deal id generated when initiating address creates the bet
    @returns true if all goes well
    @dev - this function closes the bet when both parties stake same amount, deposits the staked amount to compound, calls delay
    */
    
    function joinDeal(uint _dealId,uint _groupId,uint _upOrDown) external payable returns(bool) {
        
        
        Deal storage deal=deals[_dealId];
        require(msg.value>0,"Need to stake non-zero amount");
        require(deal.state==0 || deal.state==1,"Deal already closed");
        require(deal.groupId==_groupId,"Incorrect group");

        if(deal.state==1) {
          deal.joiner2==payable(msg.sender);
          deal.dealAmount[2]=msg.value;
          deal.upOrDown[2]=_upOrDown;
          delayCaller(deal.timer,_dealId);
           deal.state=2;
           uint256 totalAmount = deal.dealAmount[0] + deal.dealAmount[1] + deal.dealAmount[2];
           depositToBento(_dealId,totalAmount);
        }


        if (deal.state==0) {
          require(deal.upOrDown[0]!=_upOrDown,"2nd participant has to bet opposite");
          deal.joiner1=payable(msg.sender);
          deal.dealAmount[1]=msg.value;
          deal.upOrDown[1]=_upOrDown;
          deal.state=1;
        }
        
        
       
        
        
        emit DealJoined(_dealId,msg.sender);
        return true;
    }

    
    /*
    @dev - this function adds the required delay before checking the result of bet at a future time
    chainlink alarm job is triggered based on required delay
    */
    function delayCaller(uint _timer,uint _dealId) internal {
        
        Chainlink.Request memory request = buildChainlinkRequest(jobId_alarm,address(this), this.fulfillDelay.selector);
        request.addUint("until",block.timestamp + _timer);
        bytes32 requestId=sendChainlinkRequestTo(oracle_alarm, request, fee);
        requestIdTimerToDealId[requestId]=_dealId;
        deals[_dealId].state=3;
        
    }
    
    /*
    @dev - this function actually triggers the call to requestPriceData to check the result of the bet
    its a public callback function which the chainlink oracle calls after required time delay
    */
    function fulfillDelay(bytes32 _requestId) public recordChainlinkFulfillment(_requestId){
        
     
        deals[requestIdTimerToDealId[_requestId]].state=4;
        requestPriceData(requestIdTimerToDealId[_requestId]);
    }
    
    /*
    @dev - this function triggers a call to the chainlink oracle for eth/usd price feed
    */
    function requestPriceData(uint _dealId) internal {
        Chainlink.Request memory request = buildChainlinkRequest(jobId_price, address(this), this.fulfill.selector);
        request.add("get", "https://min-api.cryptocompare.com/data/pricemultifull?fsyms=ETH&tsyms=USD");
        request.add("path","RAW.ETH.USD.PRICE");
        int timesAmount = 10**18;
        request.addInt("times", timesAmount);
        
        bytes32 requestId = sendChainlinkRequestTo(oracle_price, request, fee);
        requestIdPriceToDealId[requestId]=_dealId;
        deals[_dealId].state=5;
    }
    
    /*
    @dev - this function is called by the chainlink pricefeed oracle with the result of the bet - price of ETH in USD
    it checks the result, updates the deal based on dealId, calculates the units for the winners, distributes total staked amount in the 
    pool to the winner using an InstantDistributionAgreement, then optionally starts the stream to ricochet to DCA buy KLIMA
    thereby removing carbon offsets from the market
    */
    function fulfill(bytes32 _requestId, uint256 _result) public recordChainlinkFulfillment(_requestId) {
        
        uint dealId=requestIdPriceToDealId[_requestId];
        Deal storage deal=deals[dealId];
        deal.result=_result;
        uint winnerFlag=0;
        if(_result >= deal.val*(10**18)) {
            winnerFlag=1;
        }

        withdrawFromBento(dealId);
        upgrade(deal.amountBento);
        //decide winner addresses and store in winners array
        //calculate units & update index
        //distribute funds
        //claim for each participant
        uint winnerPie=0;
        uint128[] memory units=new uint128[](3);
        uint256 totalAmount = deal.dealAmount[0] + deal.dealAmount[1] + deal.dealAmount[2];
        for(uint i=0;i<3;i++) {
          if(deal.upOrDown[i]==winnerFlag) {
            deal.winners[i]=true;
            winnerPie+=deal.dealAmount[i];
          }
        }
     
        for(uint i=0;i<3;i++) {
          if(deal.winners[i]) {
            units[i]=(uint128)((deal.dealAmount[i]*100)/winnerPie);
          }
          else {
            units[i]=0;
          }
        }

        update(deal.initiator,units[0],deal.groupId);
        update(deal.joiner1,units[1],deal.groupId);
        update(deal.joiner2,units[2],deal.groupId);

        dist(deal.groupId,totalAmount);

        claim(deal.initiator,deal.groupId);
        claim(deal.joiner1,deal.groupId);
        claim(deal.joiner2,deal.groupId);

        //buyKlimaFromRicochet(dealId);
        deal.state=6;
        emit DealCompleted(dealId);
    }
   
    /*
    function buyKimaFromRicochet(uint dealId) public {

    }*/
    fallback() external payable {}

    receive() external payable{}
    
    function convertToMatic(uint256 amount) public {
        IERC20 wmatic = IERC20(address(0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889));
        wmatic.withdraw(amount);
    }


    ///@notice - just gets wrapped matic corresponding to a particular amount of matic
    function getWMatic(uint256 amt) public {
        IERC20 wmatic = IERC20(address(0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889));
        wmatic.deposit{value:amt}();
        
    }

    
    function getChainlinkTokenAddress() public view returns (address) {
        return chainlinkTokenAddress();
    }
    
    function setChainlinkTokenAddress(address _add) public onlyOwner() {
        setChainlinkToken(_add);
    }
    
}