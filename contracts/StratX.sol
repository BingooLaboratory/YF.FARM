// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "./interfaces/IDexRouter.sol";
import "./interfaces/IDexPair.sol";
import "./interfaces/IFarmPool.sol";
import "./interfaces/IYFPool.sol";
import "./LpSpell.sol";

interface ISwapMining {
    function takerWithdraw() external;
    function mdx() external returns (address);
}

contract StratX is Ownable, ReentrancyGuard, Pausable, LpSpell {
    // Maximize yields in HecoPool

    using SafeMath for uint;
    using SafeERC20 for IERC20;

    address public governor; // timelock contract
    modifier onlyGov() {
        require(msg.sender == governor, 'not the governor');
        _;
    }

    bool public isErc20Token; // isn't LP token.
    bool public isAutoComp; // this vault is purely for staking. eg. liquidity pool vault.

    IFarmPool public farmPool; // address of farm, eg, Heco, Bsc etc.
    uint public pid; // pid of pool in farm

    address public constant USDT = 0xa71EdC38d189767582C38A3145b5873052c3e47a;
    address public immutable YFToken;

    address public treasury;
    address public custodian;

    address public immutable desire; // deposit token
    address public token0; // lp token0 iff deposit is lp token
    address public token1; // lp token1 iff deposit is lp token
    address public immutable earned; // earned token

    uint public lastEarnBlock = 0;
    uint public sharesTotal = 0;
    uint public wantLockedTotal = 0;

    uint public withdrawFee = 20;
    uint public constant WITHDRAW_FEE_MAX = 100000; // 1000 = 1%

    uint256 public controllerFee1 = 100;
    uint256 public controllerFee2 = 300;
    uint256 public controllerFee3 = 300;
    uint256 public constant CONTROLLER_FEE_MAX = 10000; // 100 = 1%

    uint256 public buybackRate = 300;
    uint256 public constant BUY_BACK_RATE_MAX = 10000; // 100 = 1%

    address[] public earnedToDesirePath;
    address[] public earnedToToken0Path;
    address[] public earnedToToken1Path;
    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;

    constructor(
        IDexRouter router_,
        IYFPool pool_,
        address token_,

        bool isErc20Token_,
        bool isAutoComp_,

        IFarmPool farmPool_,
        uint pid_,

        address desire_,
        address token0_,
        address token1_,
        address earned_
    ) LpSpell(router_, pool_) public {
        require(token_ != address(0), "Zero address");
        require(desire_ != address(0), "Zero address");

        transferOwnership(address(pool_));
        governor = msg.sender;

        YFToken = token_;

        isErc20Token = isErc20Token_;
        isAutoComp = isAutoComp_;

        desire = desire_;
        earned = earned_;

        if (!isErc20Token) {
            token0 = token0_;
            token1 = token1_;
        }

        if (isAutoComp) {
            farmPool = farmPool_;
            pid = pid_;

            earnedToDesirePath = [earned_, WHT, desire_];
            if (WHT == earned_) {
                earnedToDesirePath = [WHT, desire_];
            }

            earnedToToken0Path = [earned_, WHT, token0];
            if (WHT == token0) {
                earnedToToken0Path = [earned_, WHT];
            }

            earnedToToken1Path = [earned_, WHT, token1];
            if (WHT == token1) {
                earnedToToken1Path = [earned_, WHT];
            }

            token0ToEarnedPath = [token0, WHT, earned_];
            if (WHT == token0) {
                token0ToEarnedPath = [WHT, earned_];
            }

            token1ToEarnedPath = [token1, WHT, earned_];
            if (WHT == token1) {
                token1ToEarnedPath = [WHT, earned_];
            }
        }
    }

    function addLiquidityWERC20(
        Amounts calldata amt
    ) external payable override {
        require(!isErc20Token, "spell supported LP token only");

        // 1-5. add liquidity
        addLiquidityInternal(token0, token1, desire, amt);

        // only staked
        if (!isAutoComp) {
            ensureApprove(desire, address(pool));
        }

        // 6. Refund leftovers to users
        doRefundETH();
        doRefund(token0);
        doRefund(token1);
    }

    // Receives new deposits from user
    function deposit(address _userAddress, uint _wantAmt)
        public
        onlyOwner
        whenNotPaused
        returns (uint)
    {
        // Shh...
        _userAddress;

        uint sharesAdded = _wantAmt;
        if (wantLockedTotal > 0) {
            sharesAdded = _wantAmt
                .mul(sharesTotal)
                .div(wantLockedTotal);
        }
        sharesTotal = sharesTotal.add(sharesAdded);

        if (isAutoComp) {
            _farm();
        } else {
            wantLockedTotal = wantLockedTotal.add(_wantAmt);
        }

        return sharesAdded;
    }

    function _farm() internal {
        uint wantAmt = IERC20(desire).balanceOf(address(this));
        wantLockedTotal = wantLockedTotal.add(wantAmt);

        ensureApprove(desire, address(farmPool));
        farmPool.deposit(pid, wantAmt);
    }

    function farm() public whenNotPaused {
        _farm();
    }

    function withdraw(address _userAddress, uint _wantAmt)
        public
        onlyOwner
        nonReentrant
        returns (uint)
    {
        require(_wantAmt > 0, "_wantAmt <= 0");

        if (isAutoComp) {
            farmPool.withdraw(pid, _wantAmt);
        }

        uint wantAmt = IERC20(desire).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint fee = _wantAmt.mul(withdrawFee).div(WITHDRAW_FEE_MAX);
        uint sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);

        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        // Withdraw fee: 0.02%
        IERC20(desire).safeTransfer(custodian, fee);
        if (isErc20Token) {
            IERC20(desire).safeTransfer(_userAddress, _wantAmt.sub(fee));
        } else {
            WithdrawAmounts memory amt = WithdrawAmounts(_wantAmt.sub(fee), 0, 0);
            removeLiquidityInternal(token0, token1, desire, amt);
        }

        return sharesRemoved;
    }

    // 1. Harvest farm tokens
    // 2. Converts farm tokens into want tokens
    // 3. Deposits want tokens
    function earn() public whenNotPaused {
        require(isAutoComp, "!isAutoComp");

        // Harvest farm tokens
        farmPool.withdraw(pid, 0);
        lastEarnBlock = block.number;

        // Converts farm tokens into want tokens
        uint earnedAmt = IERC20(earned).balanceOf(address(this));
        if (earnedAmt <= 0) return;

        ensureApprove(earned, address(router));
        earnedAmt = distributeHarvest(earnedAmt);

        // Single token autocomp
        if (isErc20Token) {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt,
                0,
                earnedToDesirePath,
                address(this),
                now
            );

            _farm();
            return;
        }

        // LP token autocomp
        if (earned != token0) {
            // Swap half earned to token0
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken0Path,
                address(this),
                now + 60
            );
        }

        if (earned != token1) {
            // Swap half earned to token1
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                earnedAmt.div(2),
                0,
                earnedToToken1Path,
                address(this),
                now + 60
            );
        }

        // Get desire tokens, ie. add liquidity
        uint token0Amt = IERC20(token0).balanceOf(address(this));
        uint token1Amt = IERC20(token1).balanceOf(address(this));

        if (token0Amt > 0 && token1Amt > 0) {
            ensureApprove(token0, address(router));
            ensureApprove(token1, address(router));
            router.addLiquidity(
                token0,
                token1,
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                now
            );
        }

        _farm();
    }

    function distributeHarvest(uint earnedAmt_) internal returns (uint) {
        // Convert earned to USDT
        uint fee_ = earnedAmt_.mul(
                controllerFee1.add(controllerFee2).add(controllerFee3)
            ).div(CONTROLLER_FEE_MAX);
        uint buyback_ = earnedAmt_.mul(buybackRate).div(BUY_BACK_RATE_MAX);
        uint harvest_ = earnedAmt_.sub(fee_).sub(buyback_).div(2);

        {
            // Transmit: Harvest
            IERC20(earned).safeTransfer(address(pool), harvest_);

            // Transmit: USDT
            address[] memory path = new address[](3);
            (path[0], path[1], path[2]) = (earned, WHT, USDT);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                fee_,
                0,
                path,
                address(this),
                now
            );
            uint usd_0 = IERC20(USDT).balanceOf(address(this));
            uint usd_1 = usd_0.mul(controllerFee1).div(CONTROLLER_FEE_MAX); // 1%
            uint usd_2 = usd_0.mul(controllerFee2).div(CONTROLLER_FEE_MAX); // 3%
            uint usd_3 = usd_0.sub(usd_1).sub(usd_2);

            IERC20(USDT).safeTransfer(custodian, usd_1);
            IERC20(USDT).safeTransfer(treasury, usd_2);
            IERC20(USDT).safeTransfer(address(pool), usd_3);

            // Transmit: Buyback
            (path[0], path[1], path[2]) = (earned, WHT, YFToken);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                buyback_,
                0,
                path,
                address(this),
                now
            );
            uint yf_ = IERC20(YFToken).balanceOf(address(this));
            IERC20(YFToken).safeTransfer(address(pool), yf_);

            // transmit to pool
            pool.distributeHarvest(usd_3, yf_, harvest_);
        }

        return earnedAmt_.sub(fee_).sub(buyback_).sub(harvest_);
    }

    function convertDustToEarned() public whenNotPaused {
        require(isAutoComp, "!isAutoComp");
        require(!isErc20Token, "isErc20Token");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().
        // Converts token0 dust (if any) to earned tokens
        uint token0Amt = IERC20(token0).balanceOf(address(this));

        if (token0 != earned && token0Amt > 0) {
            ensureApprove(token0, address(router));
            // Swap all dust tokens to earned tokens
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token0Amt,
                0,
                token0ToEarnedPath,
                address(this),
                now
            );
        }

        // Converts token1 dust (if any) to earned tokens
        uint token1Amt = IERC20(token1).balanceOf(address(this));
        if (token1 != earned && token1Amt > 0) {
            ensureApprove(token1, address(router));
            // Swap all dust tokens to earned tokens
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                token1Amt,
                0,
                token1ToEarnedPath,
                address(this),
                now
            );
        }
    }

    event SetGov(address indexed gov);
    function setGov(address governor_) external onlyGov {
        require(governor_ != address(0), "Zero address");
        governor = governor_;
        emit SetGov(governor_);
    }

    event SetFundsAccount(address indexed treasury, address indexed custodian);
    function setFundsAccount(address treasury_, address custodian_) external onlyGov {
        require(treasury_ != address(0), "Zero address");
        require(custodian_ != address(0), "Zero address");

        treasury = treasury_;
        custodian = custodian_;
        emit SetFundsAccount(treasury_, custodian_);
    }

    event SetBuybackRate(uint indexed rate);
    function setBuybackRate(uint rate_) external onlyGov {
        buybackRate = rate_;
        emit SetBuybackRate(rate_);
    }

    event SetWithdrawFee(uint indexed rate);
    function setWithdrawFee(uint rate_) external onlyGov {
        require(rate_ < WITHDRAW_FEE_MAX, "Fee rate overflow");
        withdrawFee = rate_;
        emit SetWithdrawFee(rate_);
    }

    event SetControllerFee(uint indexed fee1, uint indexed fee2, uint indexed fee3);
    function setControllerFee(uint fee1, uint fee2, uint fee3) external onlyGov {
        require(fee1 + fee2 + fee3 < CONTROLLER_FEE_MAX, "Overflow of Proportions");
        controllerFee1 = fee1;
        controllerFee2 = fee2;
        controllerFee3 = fee3;
        emit SetControllerFee(fee1, fee2, fee3);
    }

    function pause() external onlyGov {
        _pause();
    }

    function unpause() external onlyGov {
        _unpause();
    }

    function inCaseTokensGetStuck(
        address _token,
        uint _amount,
        address _to
    ) external onlyGov {
        require(_token != earned, "!safe");
        require(_token != desire, "!safe");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function harvestSwapMiningReward() external {
        ISwapMining mining = ISwapMining(0x7373c42502874C88954bDd6D50b53061F018422e);
        address mdx = mining.mdx();
        uint _before = IERC20(mdx).balanceOf(address(this));
        mining.takerWithdraw();
        uint _after = IERC20(mdx).balanceOf(address(this));
        uint _reward = _after.sub(_before);
        IERC20(mdx).safeTransfer(custodian, _reward);
    }
}
