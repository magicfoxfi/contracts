// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

interface IVotingEscrow {
  function create_lock_for(uint _value, uint _lock_duration, address _to) external returns (uint);
}

interface IZap {
  function convert(
      address inputToken, 
      uint256 inputAmount, 
      address[] calldata path
    ) external payable returns (uint256);
}

contract Fairlaunch is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  struct UserInfo {
    uint256 allocationFOX; // amount taken into account to obtain FOX (amount spent + discount)
    uint256 allocationSHROOM; // amount taken into account to obtain SHROOM (amount spent + discount)
    uint256 contribution; // amount spent to buy FOX/SHROOM

    // uint256 discount; // discount % for this user
    // uint256 discountEligibleAmount; // max contribution amount eligible for a discount

    address ref; // referral for this account
    uint256 refEarnings; // referral earnings made by this account
    uint256 claimedRefEarnings; // amount of claimed referral earnings
    bool hasClaimed; // has already claimed its allocation
  }

  IERC20 public immutable FOX; // FOX token contract
  IVotingEscrow public immutable VE_FOX; // veFOX token contract
  address public FOX_LP_TOKEN; // FOX LP address

  IERC20 public immutable SHROOM; // SHROOM token contract
  IVotingEscrow public immutable VE_SHROOM; // veSHROOM token contract
  address public SHROOM_LP_TOKEN; // SHROOM LP address

  IERC20 public immutable SALE_TOKEN; // token used to participate

  uint256 public immutable START_TIME; // sale start time
  uint256 public immutable END_TIME; // sale end time

  uint256 public constant REFERRAL_SHARE = 3; // 3%

  mapping(address => UserInfo) public userInfo; // buyers and referrers info
  uint256 public totalRaised; // raised amount, does not take into account referral shares
  uint256 public totalAllocationFOX; // takes into account discounts
  uint256 public totalAllocationSHROOM; // takes into account discounts

  uint256 public constant MAX_FOX_TO_DISTRIBUTE = 583_105 ether; // max FOX amount to distribute during the sale
  uint256 public constant MAX_SHROOM_TO_DISTRIBUTE = 3_104_848 ether; // max SHROOM amount to distribute during the sale

  uint256 public constant VE_TOKEN_SHARE = 40; // ~ 40% of FOX/SHROOM bought is returned as veFOX/veSHROOM

  address public immutable treasury; // treasury multisig, will receive raised amount
  IZap public immutable zap;

  constructor(
    IERC20 foxToken, 
    IVotingEscrow veFoxToken, 
    IERC20 shroomToken, 
    IVotingEscrow veShroomToken, 
    IERC20 saleToken, 
    uint256 startTime, 
    uint256 endTime, 
    address treasury_,
    IZap zap_
  ) {
    require(startTime < endTime, "invalid dates");
    require(treasury_ != address(0), "invalid treasury");
    require(address(zap_) != address(0), "invalid zap");

    FOX = foxToken;
    VE_FOX = veFoxToken;
    SHROOM = shroomToken;
    VE_SHROOM = veShroomToken;
    SALE_TOKEN = saleToken;
    START_TIME = startTime;
    END_TIME = endTime;
    treasury = treasury_;
    zap = zap_;

    // set max approval for veFOX/veSHROOM locking
    FOX.approve(address(VE_FOX), type(uint256).max);
    SHROOM.approve(address(VE_SHROOM), type(uint256).max);
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event Buy(address indexed user, uint256 amount);
  event ClaimRefEarnings(address indexed user, uint256 amount);
  event Claim(address indexed user, uint256 fox, uint256 veFox, uint256 shroom, uint256 veShroom);
  event NewRefEarning(address referrer, uint256 amount);
  event DiscountUpdated();

  event EmergencyWithdraw(address token, uint256 amount);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /**
   * @dev Check whether the sale is currently active
   *
   * Will be marked as inactive if FOX/SHROOM has not been deposited into the contract
   */
  modifier isSaleActive() {
    require(
      hasStarted() && 
      !hasEnded() && 
      FOX.balanceOf(address(this)) >= MAX_FOX_TO_DISTRIBUTE &&
      SHROOM.balanceOf(address(this)) >= MAX_SHROOM_TO_DISTRIBUTE, 
      "isActive: sale is not active"
    );
    _;
  }

  /**
   * @dev Check whether users can claim their purchased FOX/SHROOM
   *
   * Sale must have ended, and LP tokens must have been formed with liquidity
   */
  modifier isClaimable(){
    require(hasEnded(), "isClaimable: sale has not ended");
    require(
      FOX_LP_TOKEN != address(0) && IERC20(FOX_LP_TOKEN).totalSupply() > 0, 
      "isClaimable: no FOX LP tokens"
    );
    require(
      SHROOM_LP_TOKEN != address(0) && IERC20(SHROOM_LP_TOKEN).totalSupply() > 0, 
      "isClaimable: no SHROOM LP tokens"
    );
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  /**
  * @dev Get remaining duration before the end of the sale
  */
  function getRemainingTime() external view returns (uint256){
    if (hasEnded()) return 0;
    return END_TIME.sub(_currentBlockTimestamp());
  }

  /**
  * @dev Returns whether the sale has already started
  */
  function hasStarted() public view returns (bool) {
    return _currentBlockTimestamp() >= START_TIME;
  }

  /**
  * @dev Returns whether the sale has already ended
  */
  function hasEnded() public view returns (bool){
    return END_TIME <= _currentBlockTimestamp();
  }

  /**
  * @dev Get user share times 1e5
    */
  function getExpectedClaimAmounts(address account) 
    public 
    view 
    returns (uint256 foxAmt, uint256 veFoxAmt, uint256 shroomAmt, uint256 veShroomAmt) 
  {
    if(totalAllocationFOX == 0) return (0, 0, 0, 0);

    UserInfo memory user = userInfo[account];

    // calc FOX/veFOX
    uint256 totalFoxAmount = user.allocationFOX.mul(MAX_FOX_TO_DISTRIBUTE).div(totalAllocationFOX);
    veFoxAmt = totalFoxAmount.mul(VE_TOKEN_SHARE).div(100);
    foxAmt = totalFoxAmount.sub(veFoxAmt);

    // calc SHROOM/veSHROOM
    uint256 totalShroomAmount = user.allocationSHROOM.mul(MAX_SHROOM_TO_DISTRIBUTE).div(totalAllocationSHROOM);
    veShroomAmt = totalShroomAmount.mul(VE_TOKEN_SHARE).div(100);
    shroomAmt = totalShroomAmount.sub(veShroomAmt);
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  function buy(uint256 amount, address referralAddress) external isSaleActive nonReentrant {
    _buy(amount, referralAddress, false);
  }

  function zapAndBuy(
    address inputToken, 
    uint256 inputAmount, 
    address[] calldata path,
    address referralAddress
  ) external payable isSaleActive nonReentrant {
    require(
        path[0] == address(inputToken),
        "wrong path path[0]"
    );
    require(
        path[path.length - 1] == address(SALE_TOKEN),
        "wrong path path[-1]"
    );

    uint256 amount = zap.convert{value: msg.value}(
      inputToken,
      inputAmount,
      path
    );

    _buy(amount, referralAddress, true);
  }

  /**
   * @dev Claim referral earnings
   */
  function claimRefEarnings() public {
    UserInfo storage user = userInfo[msg.sender];
    uint256 toClaim = user.refEarnings.sub(user.claimedRefEarnings);

    if(toClaim > 0){
      user.claimedRefEarnings = user.claimedRefEarnings.add(toClaim);

      emit ClaimRefEarnings(msg.sender, toClaim);
      SALE_TOKEN.safeTransfer(msg.sender, toClaim);
    }
  }

  /**
   * @dev Claim purchased FOX/SHROOM during the sale
   */
  function claim() external isClaimable {
    UserInfo storage user = userInfo[msg.sender];

    require(totalAllocationFOX > 0 && user.allocationFOX > 0, "claim: zero allocation");
    require(!user.hasClaimed, "claim: already claimed");
    user.hasClaimed = true;

    (
      uint256 foxAmount, 
      uint256 veFoxAmount,
      uint256 shroomAmount, 
      uint256 veShroomAmount
    ) = getExpectedClaimAmounts(msg.sender);

    emit Claim(msg.sender, foxAmount, veFoxAmount, shroomAmount, veShroomAmount);

    // send FOX and lock veFOX
    if(veFoxAmount > 0) {
      VE_FOX.create_lock_for(veFoxAmount, 365 days, msg.sender);
    }
    _safeClaimTransfer(address(FOX), msg.sender, foxAmount);

    // send SHROOM and lock veSHROOM
    if(veShroomAmount > 0) {
      VE_SHROOM.create_lock_for(veShroomAmount, 365 days, msg.sender);
    }
    _safeClaimTransfer(address(SHROOM), msg.sender, shroomAmount);
  }

  /****************************************************************/
  /********************** OWNABLE FUNCTIONS  **********************/
  /****************************************************************/

  struct DiscountSettings {
    address account;
    uint256 discount;
    uint256 eligibleAmount;
  }

  function setLpTokens(address _foxLpToken, address _shroomLpToken) external onlyOwner {
    require(_foxLpToken != address(0), "Zero address not allowed.");
    require(_shroomLpToken != address(0), "Zero address not allowed.");
    FOX_LP_TOKEN = _foxLpToken;
    SHROOM_LP_TOKEN = _shroomLpToken;
  }

  /********************************************************/
  /****************** /!\ EMERGENCY ONLY ******************/
  /********************************************************/

  /**
   * @dev Failsafe
   */
  function emergencyWithdrawFunds(address token, uint256 amount) external onlyOwner {
    IERC20(token).safeTransfer(msg.sender, amount);

    emit EmergencyWithdraw(token, amount);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Purchase an allocation for the sale for a value of "amount" SALE_TOKEN, referred by "referralAddress"
   */
  function _buy(uint256 amount, address referralAddress, bool isZap) private {
    require(amount > 0, "buy: zero amount");

    uint256 participationAmount = amount;
    UserInfo storage user = userInfo[msg.sender];

    // handle user's referral
    if (user.allocationFOX == 0 && user.ref == address(0) && referralAddress != address(0) && referralAddress != msg.sender) {
      // If first buy, and does not have any ref already set
      user.ref = referralAddress;
    }
    referralAddress = user.ref;

    if (referralAddress != address(0)) {
      UserInfo storage referrer = userInfo[referralAddress];

      // compute and send referrer share
      uint256 refShareAmount = REFERRAL_SHARE.mul(amount).div(100);
      SALE_TOKEN.safeTransferFrom(
        isZap ? address(zap) : msg.sender, 
        address(this), 
        refShareAmount
      );

      referrer.refEarnings = referrer.refEarnings.add(refShareAmount);
      participationAmount = participationAmount.sub(refShareAmount);

      emit NewRefEarning(referralAddress, refShareAmount);
    }

    // 50% in FOX
    uint256 allocationFOX = amount.mul(50).div(100);
    // 50% in SHROOM
    uint256 allocationSHROOM = amount - allocationFOX;

    // update raised amounts
    user.contribution = user.contribution.add(amount);
    totalRaised = totalRaised.add(amount);

    // update allocations
    user.allocationFOX = user.allocationFOX.add(allocationFOX);
    totalAllocationFOX = totalAllocationFOX.add(allocationFOX);

    user.allocationSHROOM = user.allocationSHROOM.add(allocationSHROOM);
    totalAllocationSHROOM = totalAllocationSHROOM.add(allocationSHROOM);

    emit Buy(msg.sender, amount);
    // transfer contribution to treasury
    SALE_TOKEN.safeTransferFrom(
      isZap ? address(zap) : msg.sender, 
      treasury, 
      participationAmount
    );
  }

  /**
   * @dev Safe token transfer function, in case rounding error causes contract to not have enough tokens
   */
  function _safeClaimTransfer(address token, address to, uint256 amount) internal {
    uint256 bal = IERC20(token).balanceOf(address(this));
    
    if (amount > bal) {
      amount = bal;
    }

    require(
      IERC20(token).transfer(to, amount), 
      "safeClaimTransfer: Transfer failed"
    );
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    return block.timestamp;
  }
}