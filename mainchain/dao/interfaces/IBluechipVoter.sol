// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IBluechipVoter {
    function _ve() external view returns (address);
    function governor() external view returns (address);
    function factory() external view returns (address);
    function minter() external view returns(address);
    function emergencyCouncil() external view returns (address);
    function attachTokenToGauge(uint _tokenId, address account) external;
    function detachTokenFromGauge(uint _tokenId, address account) external;
    function emitDeposit(uint _tokenId, address account, uint amount) external;
    function emitWithdraw(uint _tokenId, address account, uint amount) external;
    function notifyRewardAmount(uint amount) external;
    function distribute(address _gauge) external;
    function distributeAll() external;
    function distributeFees(address[] memory _gauges) external;

    function usedWeights(uint id) external view returns(uint);
    function lastVoted(uint id) external view returns(uint);
    function gaugeVote(uint id, uint _index) external view returns(address _pair);
    function votes(uint id, address _pool) external view returns(uint votes);
    function gaugeVoteLength(uint tokenId) external view returns(uint);
    
}
