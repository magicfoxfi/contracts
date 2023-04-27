// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "../chainlink/AutomationCompatible.sol";
import "../dao/interfaces/IMinter.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

interface IVoter {
    function distributeSidechainAll(uint16 chainId, uint256 period, uint256 dstGasLimit) external payable;
}

contract WeeklyEmissionBridge is AutomationCompatibleInterface, OwnableUpgradeable {

    address public automationRegistry;

    address public minter;
    address public voter;
    address public bluechipVoter;

    mapping(uint256 => mapping(address => bool)) public epochEmissionsBridged;
    uint16 public LZ_CHAIN_ID;
    uint256 public dstGasLimit;
    uint256 public minLzValue;

    constructor() {}

    function initialize(
        address _minter,
        address _voter,
        address _bluechipVoter,
        uint256 _dstGasLimit,
        uint16 _chainId,
        uint256 _minLzValue
    ) public initializer {
        __Ownable_init();
        minter = _minter;
        voter = _voter;
        bluechipVoter = _bluechipVoter;
        dstGasLimit = _dstGasLimit;
        LZ_CHAIN_ID = _chainId;
        minLzValue = _minLzValue;
        automationRegistry = address(0x02777053d6764996e594c3E88AF1D58D5363a2e6);
    }


    function checkUpkeep(bytes memory /*checkdata*/) public view override returns (bool upkeepNeeded, bytes memory /*performData*/) {
        if (address(this).balance > minLzValue) {
            uint256 active_period = IMinter(minter).active_period();
            if (!epochEmissionsBridged[active_period][voter]) {
                upkeepNeeded = true;
            } else if (!epochEmissionsBridged[active_period][bluechipVoter]) {
                upkeepNeeded = true;
            } 
        }
    }

    function performUpkeep(bytes calldata /*performData*/) external override {
        require(msg.sender == automationRegistry || msg.sender == owner(), 'cannot execute');
        (bool upkeepNeeded, ) = checkUpkeep('0');
        require(upkeepNeeded, "condition not met");

        uint256 active_period = IMinter(minter).active_period();

        address ua;
        if(!epochEmissionsBridged[active_period][voter]){
            ua = voter;
        } else if(!epochEmissionsBridged[active_period][bluechipVoter]){
            ua = bluechipVoter;
        } else {
            revert("Invalid UA contract");
        }

        IVoter(ua).distributeSidechainAll{value: minLzValue}(LZ_CHAIN_ID, active_period, dstGasLimit);

        epochEmissionsBridged[active_period][ua] = true;
    }

    function setAutomationRegistry(address _automationRegistry) external onlyOwner {
        require(_automationRegistry != address(0));
        automationRegistry = _automationRegistry;
    }

    function setVoter(address _voter) external onlyOwner {
        require(_voter != address(0));
        voter = _voter;
    }

    function setBluechipVoter(address _bluechipVoter) external onlyOwner {
        require(_bluechipVoter != address(0));
        bluechipVoter = _bluechipVoter;
    }

    function setMinter(address _minter ) external onlyOwner {
        require(_minter != address(0));
        minter = _minter;
    }

    function setDstGasLimit(uint256 _dstGasLimit) external onlyOwner {
        require(_dstGasLimit >= 1_000_000);
        dstGasLimit = _dstGasLimit;
    }

    function setMinLzValue(uint256 _minLzValue) external onlyOwner {
        minLzValue = _minLzValue;
    }

    function resetForActivePeriod() external onlyOwner {
        uint256 active_period = IMinter(minter).active_period();
        epochEmissionsBridged[active_period][voter] = false;
        epochEmissionsBridged[active_period][bluechipVoter] = false;
    }

    receive() external payable {}

    function withdraw() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

}