// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IRouter {
  function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

contract FairlaunchZap is Ownable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  address public immutable SALE_TOKEN; // token used to participate

  mapping(address => bool) public whitelistedTokens;
  IRouter public constant router = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
  address public fairlaunch;
  address public wnative;

  constructor (address _wnative, address saleToken) {
    wnative = _wnative; // Should be 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c for BNB
    SALE_TOKEN = saleToken;
  }

  function whitelistTokens(address[] calldata _tokens, bool whitelist) external onlyOwner {
    for (uint i = 0; i < _tokens.length; i++) {
      whitelistedTokens[_tokens[i]] = whitelist;
    }
  }

  function convert(
    address buyer,
    address inputToken, 
    uint256 inputAmount, 
    address[] calldata path
  ) external payable returns(uint256) {
    require(msg.sender == fairlaunch, 'Unauthorized');
    require(
        whitelistedTokens[inputToken],
        "inputToken is not whitelisted"
    );
    require(
        path[path.length - 1] == SALE_TOKEN,
        "wrong path path[-1]"
    );

    if (inputToken != address(0)) {
      require(path[0] == inputToken, "wrong path path[0]");
      require(msg.value == 0, "Value sent for non native token");
      IERC20(inputToken).safeTransferFrom(
        buyer, 
        address(this), 
        inputAmount
      );

      IERC20(inputToken).approve(address(router), inputAmount);
      router.swapExactTokensForTokens(
          inputAmount,
          0,
          path,
          address(this),
          block.timestamp
      );
    } else {
      require(path[0] == wnative, "wrong path path[0]");
      require(msg.value > 0, "No value sent");
      router.swapExactETHForTokens{value: msg.value}(
          0,
          path,
          address(this),
          block.timestamp
      );
    }

    address outputToken = path[path.length - 1];
    uint256 outputTokenAmount = IERC20(outputToken).balanceOf(address(this));
    // Approve fairlaunch contract to spend USDC and buy for user
    IERC20(outputToken).approve(fairlaunch, outputTokenAmount);

    return outputTokenAmount;
  }

  function setFairlaunch(address _fairlaunch) external onlyOwner {
    require(_fairlaunch != address(0));
    fairlaunch = _fairlaunch;
  }

}