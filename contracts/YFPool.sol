// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interfaces/IYFToken.sol";
import "./interfaces/IYFPool.sol";
import "./interfaces/IStrategy.sol";

contract YFCaster {
  /// @dev Call to the target using the given data.
  /// @param target The address target to call.
  /// @param data The data used in the call.
  function cast(address target, bytes calldata data) external payable {
    (bool ok, bytes memory returndata) = target.call{value: msg.value}(data);

    if (!ok) {
      if (returndata.length > 0) {
        // The easiest way to bubble the revert reason is using memory via assembly
        // solhint-disable-next-line no-inline-assembly
        assembly {
          let returndata_size := mload(returndata)
          revert(add(32, returndata), returndata_size)
        }
      } else {
        revert('bad cast call');
      }
    }
  }
}

contract YFPool is Ownable, ReentrancyGuard, IYFPool {
    using SafeMath for uint;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint public totalYAllocPoint = 0; // Total YF allocation points. Must be the sum of all allocation points in all pools.
    uint public totalUAllocPoint = 0;
    uint public totalBAllocPoint = 0;

    // Info of each user.
    struct UserInfo {
        uint shares;     // How many want tokens the user has provided.
        uint capitals;

        uint rewardYDebt; // Reward YF debt
        uint rewardUDebt; // Reward USDT debt
        uint rewardHDebt; // Reward farm harvest debt
        // We do some fancy math here. Basically, any point in time, the amount of YFToken
        // entitled to a user but is pending to be distributed is:
        //
        //   amount = user.shares / sharesTotal * wantLockedTotal
        //   pending reward = (amount * pool.accPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws want tokens to a pool. Here's what happens:
        //   1. The pool's `accPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    struct PoolInfo {
        address want;    // Address of the want token.
        address earned;  // Address of the harvest token.
        IStrategy strat; // Strategy address that will auto compound want tokens

        uint allocYPoint; // How many allocation points assigned to this pool. YFToken to distribute per block.
        uint allocUPoint;
        uint allocBPoint; // How many allocation points assigned to buyback YFToken

        uint lastRewardBlock; // Last block number that YFToken distribution occurs.

        uint accYPerShare; // Accumulated YFToken per share, times 1e12. See below.
        uint accUPerShare;
        uint accHPerShare;
    }

    EnumerableSet.AddressSet whitelist;
    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);

    address public immutable caster; // The caster address for untrusted execution.
    address public immutable YFToken;
    address public constant USDT = 0xa71EdC38d189767582C38A3145b5873052c3e47a;

    uint public constant startBlock = 4048888;
    uint public constant YFTokenMaxSupply = 300e18;
    uint public constant YFTokenPerBlock  = 350000000000000;  // YF tokens created per block

    address private constant _NO_ADDRESS = address(1);
    address public override EXECUTOR; // TEMPORARY: user currently under execution.

    constructor(address YFToken_) public {
        require(YFToken_ != address(0), "Zero address");

        YFToken = YFToken_;
        caster = address(new YFCaster());
        EXECUTOR = _NO_ADDRESS;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // *** DO NOT add the same LP token more than once.
    // *** Rewards will be messed up if you do. (Only if want tokens are stored here.)
    function add(
        bool _withUpdate,

        uint _allocYPoint,
        uint _allocUPoint,
        uint _allocBPoint,

        address _want,
        address _earned,
        IStrategy _strat
    ) public override onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalYAllocPoint = totalYAllocPoint.add(_allocYPoint);
        totalUAllocPoint = totalUAllocPoint.add(_allocUPoint);
        totalBAllocPoint = totalBAllocPoint.add(_allocBPoint);

        poolInfo.push(
            PoolInfo({
                want:            _want,
                earned:          _earned,
                strat:           _strat,

                allocYPoint:     _allocYPoint,
                allocUPoint:     _allocUPoint,
                allocBPoint:     _allocBPoint,

                lastRewardBlock: lastRewardBlock,

                accYPerShare: 0,
                accUPerShare: 0,
                accHPerShare: 0
            })
        );

        whitelist.add(address(_strat));
    }

    // Update the given pool's YFToken allocation point. Can only be called by the owner.
    function set(
        bool _withUpdate,
        uint _pid,

        uint _allocYPoint,
        uint _allocUPoint,
        uint _allocBPoint
    ) public override onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolInfo storage pool = poolInfo[_pid];

        totalYAllocPoint = totalYAllocPoint.sub(pool.allocYPoint).add(
            _allocYPoint
        );
        totalUAllocPoint = totalUAllocPoint.sub(pool.allocUPoint).add(
            _allocUPoint
        );
        totalBAllocPoint = totalBAllocPoint.sub(pool.allocBPoint).add(
            _allocBPoint
        );

        pool.allocYPoint = _allocYPoint;
        pool.allocUPoint = _allocUPoint;
        pool.allocBPoint = _allocBPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint _from, uint _to) public view returns (uint) {
        if (IERC20(YFToken).totalSupply() >= YFTokenMaxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint sharesTotal = pool.strat.sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }

        uint reward =
            multiplier.mul(YFTokenPerBlock).mul(pool.allocYPoint).div(
                totalYAllocPoint
            );

        IYFToken(YFToken).mint(address(this), reward);

        pool.accYPerShare = pool.accYPerShare.add(
            reward.mul(1e12).div(sharesTotal)
        );
        pool.lastRewardBlock = block.number;
    }

    function distributeHarvest(uint fee_, uint buyback_, uint harvest_) external override {
        require(whitelist.contains(msg.sender), "invalid strategy");
        uint length = poolInfo.length;

        for (uint i = 0; i < length; i++) {
            PoolInfo storage pool = poolInfo[i];
            uint sharesTotal = pool.strat.sharesTotal();

            // 45% MDX
            if (address(pool.strat) == msg.sender) {
                if (sharesTotal > 0) {
                    pool.accHPerShare = pool.accHPerShare.add(
                        harvest_.mul(1e12).div(sharesTotal)
                    );
                }
            }

            // 3% USDT
            if (pool.allocUPoint > 0) {
                uint reward = fee_.mul(pool.allocUPoint).div(totalUAllocPoint);
                if (sharesTotal > 0) {
                    pool.accUPerShare = pool.accUPerShare.add(
                        reward.mul(1e12).div(sharesTotal)
                    );
                }
            }

            // 3% Buyback YF
            if (pool.allocBPoint > 0) {
                uint reward = buyback_.mul(pool.allocBPoint).div(totalBAllocPoint);
                if (sharesTotal > 0) {
                    pool.accYPerShare = pool.accYPerShare.add(
                        reward.mul(1e12).div(sharesTotal)
                    );
                }
            }
        }
    }

    /// @dev View function to see staked Want tokens on frontend.
    /// @param _pid id of pool.
    /// @param _user the user to staked
    /// @return the total staked
    /// @return the capitals
    function stakedWantTokens(uint _pid, address _user)
        external
        view
        returns (uint, uint)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint sharesTotal     = pool.strat.sharesTotal();
        uint wantLockedTotal = pool.strat.wantLockedTotal();

        if (sharesTotal == 0) {
            return (0, 0);
        }
        return (user.shares.mul(wantLockedTotal).div(sharesTotal), user.capitals);
    }

    /// @dev View function to see pending KToken on frontend.
    /// @param _pid id of pool.
    /// @param _user the user to staked
    /// @return r1_ the YF pending
    /// @return r2_ the USDT pending
    /// @return r3_ the `earned token` pending
    function pending(uint _pid, address _user)
        external
        override
        view
        returns (uint r1_, uint r2_, uint r3_)
    {
        (r1_, r2_, r3_) = _pending(_pid, _user);
    }

    function _pending(uint _pid, address _user)
        internal
        view
        returns (uint r1_, uint r2_, uint r3_)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint sharesTotal = pool.strat.sharesTotal();
        if (sharesTotal > 0) {
            r1_ = pool.accYPerShare;
            r2_ = pool.accUPerShare;
            r3_ = pool.accHPerShare;

            if (block.number > pool.lastRewardBlock) {
                uint multiplier = getMultiplier(pool.lastRewardBlock, block.number);
                uint reward =
                    multiplier.mul(YFTokenPerBlock).mul(pool.allocYPoint).div(
                        totalYAllocPoint
                    );

                r1_ = r1_.add(
                    reward.mul(1e12).div(sharesTotal)
                );
            }

            r1_ = user.shares.mul(r1_).div(1e12).sub(user.rewardYDebt);
            r2_ = user.shares.mul(r2_).div(1e12).sub(user.rewardUDebt);
            r3_ = user.shares.mul(r3_).div(1e12).sub(user.rewardHDebt);
        }
    }

    function deposit(uint _pid, uint _wantAmt) external override nonReentrant {
        updatePool(_pid);
        EXECUTOR = msg.sender;

        // 1. Harvest all reward
        (PoolInfo storage pool, UserInfo storage user) = harvest(_pid, EXECUTOR);

        if (_wantAmt > 0) {
            // 1. only staked
            if (pool.earned == address(0)) {
                IERC20(pool.want).safeTransferFrom(EXECUTOR, address(this), _wantAmt);
            } else {
                IERC20(pool.want).safeTransferFrom(EXECUTOR, address(pool.strat), _wantAmt);
            }

            // 2. increase user shares
            uint sharesAdded = pool.strat.deposit(EXECUTOR, _wantAmt);
            user.shares = user.shares.add(sharesAdded);

            // 3. increase user capitals
            user.capitals = user.capitals.add(_wantAmt);
        }

        user.rewardYDebt = user.shares.mul(pool.accYPerShare).div(1e12);
        user.rewardUDebt = user.shares.mul(pool.accUPerShare).div(1e12);
        user.rewardHDebt = user.shares.mul(pool.accHPerShare).div(1e12);

        EXECUTOR = _NO_ADDRESS;
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    function emergencyWithdraw(uint _pid) external override nonReentrant {
        EXECUTOR = msg.sender;

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][EXECUTOR];

        uint wantLockedTotal = pool.strat.wantLockedTotal();
        uint sharesTotal = pool.strat.sharesTotal();
        uint _wantAmt = user.shares.mul(wantLockedTotal).div(sharesTotal);

        // only stake pool
        if (pool.earned == address(0)) {
            IERC20(pool.want).safeTransfer(address(pool.strat), _wantAmt);
        }
        pool.strat.withdraw(msg.sender, _wantAmt);

        user.shares      = 0;
        user.capitals    = 0;
        user.rewardYDebt = 0;
        user.rewardUDebt = 0;
        user.rewardHDebt = 0;

        EXECUTOR = _NO_ADDRESS;
        emit EmergencyWithdraw(msg.sender, _pid, _wantAmt);
    }

    function withdraw(uint _pid, uint _wantAmt) public override nonReentrant {
        updatePool(_pid);
        EXECUTOR = msg.sender;

        // 1. Harvest all reward
        (PoolInfo storage pool, UserInfo storage user) = harvest(_pid, EXECUTOR);

        uint sharesTotal     = pool.strat.sharesTotal();
        uint wantLockedTotal = pool.strat.wantLockedTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        // 2. Withdraw want tokens
        uint amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }

        if (_wantAmt > 0) {
            // only stake pool
            if (pool.earned == address(0)) {
                IERC20(pool.want).safeTransfer(address(pool.strat), _wantAmt);
            }

            uint sharesRemoved = pool.strat.withdraw(EXECUTOR, _wantAmt);
            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            if (_wantAmt > user.capitals) {
                user.capitals = 0;
            } else {
                user.capitals = user.capitals.sub(_wantAmt);
            }
        }

        user.rewardYDebt = user.shares.mul(pool.accYPerShare).div(1e12);
        user.rewardUDebt = user.shares.mul(pool.accUPerShare).div(1e12);
        user.rewardHDebt = user.shares.mul(pool.accHPerShare).div(1e12);

        EXECUTOR = _NO_ADDRESS;
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    function withdrawAll(uint _pid) public {
        withdraw(_pid, uint(-1));
    }

    // Safe transfer function, just in case if rounding error causes pool to not have enough
    function safeTransfer(address token, address _to, uint _amount) internal {
        uint bal_ = IERC20(token).balanceOf(address(this));

        if (_amount > bal_) {
            IERC20(token).transfer(_to, bal_);
        } else {
            IERC20(token).transfer(_to, _amount);
        }
    }

    /// @dev Execute the action via YFCaster, calling its function with the supplied data.
    /// @param _pid The strategy ID to execute the action.
    /// @param data Extra data to pass to the target for the execution.
    function execute(
        uint _pid,
        bytes memory data
    ) external payable nonReentrant {
        updatePool(_pid);
        EXECUTOR = msg.sender;

        // 1. Harvest all reward
        (PoolInfo storage pool, UserInfo storage user) = harvest(_pid, EXECUTOR);

        // Spell single token to lp
        YFCaster(caster).cast{value: msg.value}(address(pool.strat), data);
        uint _wantAmt = IERC20(pool.want).balanceOf(address(pool.strat));

        if (_wantAmt > 0) {
            // 1. only staked
            if (pool.earned == address(0)) {
                IERC20(pool.want).safeTransferFrom(address(pool.strat), address(this), _wantAmt);
            }

            // 2. increase user shares
            uint sharesAdded = pool.strat.deposit(EXECUTOR, _wantAmt);
            user.shares = user.shares.add(sharesAdded);

            // 3. increase user capitals
            user.capitals = user.capitals.add(_wantAmt);
        }

        user.rewardYDebt = user.shares.mul(pool.accYPerShare).div(1e12);
        user.rewardUDebt = user.shares.mul(pool.accUPerShare).div(1e12);
        user.rewardHDebt = user.shares.mul(pool.accHPerShare).div(1e12);

        EXECUTOR = _NO_ADDRESS;
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    /// @dev Harvest all reward
    function harvest(uint _pid, address _user) internal returns (PoolInfo storage, UserInfo storage) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        {
            (uint r1_, uint r2_, uint r3_) = _pending(_pid, _user);
            if (r1_ > 0) {
                safeTransfer(YFToken, _user, r1_);
            }
            if (r2_ > 0) {
                safeTransfer(USDT, _user, r2_);
            }
            if (r3_ > 0) {
                safeTransfer(pool.earned, _user, r3_);
            }
        }

        return (pool, user);
    }

    /// @dev Transmit user assets to the caller, so users only need to approve Bank for spending.
    /// @param token The token to transfer from user to the caller.
    /// @param amount The amount to transfer.
    function transmit(address token, uint amount) external override {
        require(whitelist.contains(msg.sender), "invalid strategy");
        IERC20(token).safeTransferFrom(EXECUTOR, msg.sender, amount);
    }
}
