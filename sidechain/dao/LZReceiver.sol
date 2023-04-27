// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "../lz/lzApp/NonblockingLzApp.sol";

interface IVoter {
    function lzProcessReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) external;
}

contract LZReceiver is NonblockingLzApp {
  address public voter;

  constructor(
    address _voter,
    address _lzEndpoint
  ) NonblockingLzApp(_lzEndpoint) {
    voter = _voter;
  }

  function _nonblockingLzReceive(
    uint16 _srcChainId, 
    bytes memory _srcAddress, 
    uint64 _nonce, 
    bytes memory _payload
  ) internal virtual override {
    IVoter(voter).lzProcessReceive(_srcChainId, _srcAddress, _nonce, _payload);
  }

  function setVoter(address _voter) external onlyOwner {
    voter = _voter;
  }
}
