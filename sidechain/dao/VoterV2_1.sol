// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import './libraries/Math.sol';
import './interfaces/IGauge.sol';
import './interfaces/IGaugeFactory.sol';
import './interfaces/IERC20.sol';
import './interfaces/IPair.sol';
import './interfaces/IPairFactory.sol';
import './interfaces/IVotingEscrow.sol';
import "../lz/lzApp/NonblockingLzApp.sol";
import "hardhat/console.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

interface IOFT {
    function mintWeeklyRewards(address _toAddress, uint _amount) external;
}

contract VoterV2_1 is OwnableUpgradeable, ReentrancyGuardUpgradeable {

    uint16 public constant SRC_CHAIN_ID = 102; // bsc -- LZ internal chainId numbers

    uint public active_period;

    address public _ve; // the ve token that governs these contracts
    address public factory; // the PairFactory
    address internal base;
    address public gaugefactory;
    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    address public governor; // should be set to an IGovernor
    address public emergencyCouncil; // credibly neutral party similar to Curve's Emergency DAO
    address public fees_collector;
    address public lz_receiver;

    address[] public gaugeList; // all gauges viable for incentives
    mapping(address => address) public mainChainGauges; // mainGauge => sideGauge
    mapping(address => uint) public gaugesDistributionTimestmap;
    mapping(address => address) public poolForGauge; // gauge => pool
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isAlive;

    mapping(uint256 => mapping(address => uint256)) public availableEmissions; // epoch => mainGauge => emissions
    bool public lzOneStepProcess; // whether nonblockingLzReceive also distributes or not

    event GaugeCreated(address indexed gauge, address creator, address fees_collector, address indexed pool);
    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event Deposit(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event Withdraw(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event NotifyReward(address indexed sender, address indexed reward, uint amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint amount);
    event Attach(address indexed owner, address indexed gauge, uint tokenId);
    event Detach(address indexed owner, address indexed gauge, uint tokenId);
    event LZReceive(uint256 activePeriod, uint256 totalClaimable, address[] gauges, uint256[] amounts);

    constructor() {}

    function initialize(
        address __ve, 
        address _factory, 
        address _gauges, 
        address _fees_collector
    ) initializer public {
        __Ownable_init();
        __ReentrancyGuard_init();
        _ve = __ve;
        factory = _factory;
        base = IVotingEscrow(__ve).token();
        gaugefactory = _gauges;
        governor = msg.sender;
        emergencyCouncil = msg.sender;
        fees_collector = _fees_collector;
        lzOneStepProcess = true;
    }      

    function setGovernor(address _governor) public {
        require(msg.sender == governor);
        governor = _governor;
    }

    function setEmergencyCouncil(address _council) public {
        require(msg.sender == emergencyCouncil);
        emergencyCouncil = _council;
    }

    function createGauge(address _pool, address _mainGauge) external returns (address) {
        require(msg.sender == governor, "Only governor");
        require(mainChainGauges[_mainGauge] == address(0x0), "mainchain gauge exists");
        bool isPair = IPairFactory(factory).isPair(_pool);
        address tokenA;
        address tokenB;

        if (isPair) {
            (tokenA, tokenB) = IPair(_pool).tokens();
        }

        address _gauge = IGaugeFactory(gaugefactory).createGaugeV2(base, _ve, _pool, address(this), address(0), address(0), fees_collector, isPair);
        mainChainGauges[_mainGauge] = _gauge;

        IERC20(base).approve(_gauge, type(uint).max);
        poolForGauge[_gauge] = _pool;
        isGauge[_gauge] = true;
        isAlive[_gauge] = true;
        gaugeList.push(_gauge);
        emit GaugeCreated(_gauge, msg.sender, fees_collector, _pool);
        return _gauge;
    }

    function killGauge(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(isAlive[_gauge], "gauge already dead");
        isAlive[_gauge] = false;
        emit GaugeKilled(_gauge);
    }

    function reviveGauge(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(!isAlive[_gauge], "gauge already alive");
        isAlive[_gauge] = true;
        emit GaugeRevived(_gauge);
    }

    function attachTokenToGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        require(isAlive[msg.sender]); // killed gauges cannot attach tokens to themselves
        if (tokenId > 0) IVotingEscrow(_ve).attach(tokenId);
        emit Attach(account, msg.sender, tokenId);
    }

    function emitDeposit(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        require(isAlive[msg.sender]);
        emit Deposit(account, msg.sender, tokenId, amount);
    }

    function detachTokenFromGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        if (tokenId > 0) IVotingEscrow(_ve).detach(tokenId);
        emit Detach(account, msg.sender, tokenId);
    }

    function emitWithdraw(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Withdraw(account, msg.sender, tokenId, amount);
    }

    function length() external view returns (uint) {
        return gaugeList.length;
    }

    function claimRewards(address[] memory _gauges, address[][] memory _tokens) external {
        for (uint i = 0; i < _gauges.length; i++) {
            IGauge(_gauges[i]).getReward(msg.sender, _tokens[i]);
        }
    }

    function distributeFees(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            if (IGauge(_gauges[i]).isForPair()){
                IGauge(_gauges[i]).claimFees();
            }
        }
    }

    function flipOneStepProcess() external {
        require(msg.sender == governor, "Only governor");
        lzOneStepProcess = !lzOneStepProcess;
    }

    function lzProcessReceive(uint16 _srcChainId, bytes memory, uint64, bytes memory _payload) external {
        require(msg.sender == lz_receiver, "Unauthorized");
        require(SRC_CHAIN_ID == _srcChainId, "Wrong srcChainId");

        (
            uint256 activePeriod, 
            uint256 totalClaimable, 
            address[] memory _gauges, 
            uint256[] memory _amounts
        ) = abi.decode(_payload, (uint256, uint256, address[], uint256[]));

        // Update active period if needed
        if (activePeriod > active_period) {
            active_period = activePeriod;
        }

        IOFT(base).mintWeeklyRewards(address(this), totalClaimable);

        for (uint256 i = 0; i < _gauges.length; i++) {
            availableEmissions[activePeriod][_gauges[i]] += _amounts[i];
        }

        if (lzOneStepProcess) {
            distribute(activePeriod, _gauges);
        }

        emit LZReceive(activePeriod, totalClaimable, _gauges, _amounts);
    }

    function distribute(uint256 _currentTimestamp, address[] memory _mainGauges) public nonReentrant { 
        address _mainGauge; // mainchain gauge
        address _gauge; // sidechain gauge
        for (uint256 i = 0; i < _mainGauges.length; i++) {
            _mainGauge = _mainGauges[i];
            _gauge = mainChainGauges[_mainGauge]; // get mapped gauge to mainchain gauge
            if (_gauge == address(0)) {
                // In case mainGauge isn't mapped on sidechain, this means that governor needs to createGauge on sidechain for this mainGauge
                return;
            }

            uint256 _claimable = availableEmissions[_currentTimestamp][_mainGauge];

            uint256 lastTimestamp = gaugesDistributionTimestmap[_gauge];
            // distribute only if claimable is > 0 and currentEpoch != lastepoch
            if (_claimable > 0 && lastTimestamp < _currentTimestamp) {
                IGauge(_gauge).notifyRewardAmount(base, _claimable);
                emit DistributeReward(msg.sender, _gauge, _claimable);
                gaugesDistributionTimestmap[_gauge] = _currentTimestamp;
                availableEmissions[_currentTimestamp][_mainGauge] = 0;
            }
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function setGaugeFactory(address _gaugeFactory) external {
        require(msg.sender == emergencyCouncil);
        gaugefactory = _gaugeFactory;
    }

    function setPairFactory(address _factory) external {
        require(msg.sender == emergencyCouncil);
        factory = _factory;
    }

    function killGaugeTotally(address _gauge) external {
        require(msg.sender == emergencyCouncil, "not emergency council");
        require(isAlive[_gauge], "gauge already dead");
        isAlive[_gauge] = false;
        poolForGauge[_gauge] = address(0);
        isGauge[_gauge] = false;
        isAlive[_gauge] = false;
        emit GaugeKilled(_gauge);
    }

    function increaseGaugeApprovals(address _gauge) external {
        require(msg.sender == emergencyCouncil);
        require(isGauge[_gauge] = true);
        IERC20(base).approve(_gauge, 0);
        IERC20(base).approve(_gauge, type(uint).max);
    }

    function setFeesCollector(address _fees_collector) external {
        require(msg.sender == emergencyCouncil);
        fees_collector = _fees_collector; 
    }

    function setLzReceiver(address _lz_receiver) external {
        require(msg.sender == governor);
        lz_receiver = _lz_receiver; 
    }

    // Moved minter & active_period here, because bribes contract needs it, and we don't have minter on sidechain
    function minter() external view returns (address) {
        return address(this);
    }

    function gaugeListExtended() external view returns(address[] memory, address[] memory){
        address[] memory poolList = new address[](gaugeList.length);
        for (uint i = 0; i < gaugeList.length; i++) {
            poolList[i] = poolForGauge[gaugeList[i]];
        }

        return (gaugeList, poolList);
    }
}
