// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IDexRouter.sol";
import "./interfaces/IDexPair.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IYFPool.sol";
import "./utils/HomoraMath.sol";

abstract contract LpSpell {
    using SafeMath for uint;
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => bool)) public approved;
    address public constant WHT = 0x5545153CCFcA01fbd7Dd11C0b23ba694D9509A6F;

    IDexRouter public immutable router;
    IYFPool public immutable pool;

    constructor(
        IDexRouter router_,
        IYFPool pool_
    ) public {
        router = router_;
        pool = pool_;
    }

    receive() external payable {
        require(msg.sender == WHT, 'HT must come from WHT');
    }

    /// @dev Ensure that the spell approve the given spender to spend all of its tokens.
    /// @param token The token to approve.
    /// @param spender The spender to allow spending.
    /// NOTE: This is safe because spell is never built to hold fund custody.
    function ensureApprove(address token, address spender) public {
        if (!approved[token][spender]) {
            IERC20(token).safeApprove(spender, uint(-1));
            approved[token][spender] = true;
        }
    }

    /// @dev Internal call to convert msg.value ETH to WETH inside the contract.
    function doTransmitETH() internal {
        if (msg.value > 0) {
            IWETH(WHT).deposit{value: msg.value}();
        }
    }

    /// @dev Internal call to transmit tokens from the bank if amount is positive.
    /// @param token The token to perform the transmit action.
    /// @param amount The amount to transmit.
    function doTransmit(address token, uint amount) internal {
        if (amount > 0) {
            pool.transmit(token, amount);
        }
    }

    /// @dev Internal call to refund tokens to the current bank executor.
    /// @param token The token to perform the refund action.
    function doRefund(address token) internal {
        uint balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(pool.EXECUTOR(), balance);
        }
    }

    /// @dev Internal call to refund all WETH to the current executor as native ETH.
    function doRefundETH() internal {
        uint balance = IWETH(WHT).balanceOf(address(this));
        if (balance > 0) {
            IWETH(WHT).withdraw(balance);
            (bool success, ) = pool.EXECUTOR().call{value: balance}(new bytes(0));
            require(success, 'refund ETH failed');
        }
    }

    /// @dev Compute optimal deposit amount
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amount of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    function optimalDeposit(
        uint amtA,
        uint amtB,
        uint resA,
        uint resB
    ) internal pure returns (uint swapAmt, bool isReversed) {
        if (amtA.mul(resB) >= amtB.mul(resA)) {
            swapAmt = _optimalDepositA(amtA, amtB, resA, resB);
            isReversed = false;
        } else {
            swapAmt = _optimalDepositA(amtB, amtA, resB, resA);
            isReversed = true;
        }
    }

    struct Amounts {
        uint amtAUser;
        uint amtBUser;
        uint amtLPUser;
        uint amtAMin;
        uint amtBMin;
    }

    /// @dev Compute optimal deposit amount helper.
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amount of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    /// Formula: https://blog.alphafinance.io/byot/
    function _optimalDepositA(
        uint amtA,
        uint amtB,
        uint resA,
        uint resB
    ) internal pure returns (uint) {
        require(amtA.mul(resB) >= amtB.mul(resA), 'Reversed');

        uint a = 997;
        uint b = uint(1997).mul(resA);
        uint _c = (amtA.mul(resB)).sub(amtB.mul(resA));
        uint c = _c.mul(1000).div(amtB.add(resB)).mul(resA);
        uint d = a.mul(c).mul(4);
        uint e = HomoraMath.sqrt(b.mul(b).add(d));
        uint numerator = e.sub(b);
        uint denominator = a.mul(2);

        return numerator.div(denominator);
    }

    function addLiquidityInternal(
        address tokenA,
        address tokenB,
        address lp,
        Amounts calldata amt
    ) internal {
        ensureApprove(tokenA, address(router));
        ensureApprove(tokenB, address(router));
        ensureApprove(lp, address(router));

        // 1. Get user input amounts
        doTransmitETH();
        doTransmit(tokenA, amt.amtAUser);
        doTransmit(tokenB, amt.amtBUser);
        doTransmit(lp, amt.amtLPUser);

        // 2. Calculate optimal swap amount
        uint swapAmt;
        bool isReversed;
        {
            uint amtA = IERC20(tokenA).balanceOf(address(this));
            uint amtB = IERC20(tokenB).balanceOf(address(this));
            uint resA;
            uint resB;
            if (IDexPair(lp).token0() == tokenA) {
                (resA, resB, ) = IDexPair(lp).getReserves();
            } else {
                (resB, resA, ) = IDexPair(lp).getReserves();
            }
            (swapAmt, isReversed) = optimalDeposit(amtA, amtB, resA, resB);
        }

        // 3. Swap optimal amount
        if (swapAmt > 0) {
            address[] memory path = new address[](2);
            (path[0], path[1]) = isReversed ? (tokenB, tokenA) : (tokenA, tokenB);
            router.swapExactTokensForTokens(swapAmt, 0, path, address(this), now);
        }

        // 4. Add liquidity
        uint balA = IERC20(tokenA).balanceOf(address(this));
        uint balB = IERC20(tokenB).balanceOf(address(this));
        if (balA > 0 || balB > 0) {
            router.addLiquidity(
                tokenA,
                tokenB,
                balA,
                balB,
                amt.amtAMin,
                amt.amtBMin,
                address(this),
                now
            );
        }
    }

    struct WithdrawAmounts {
        uint amtLPWithdraw;
        uint amtAMin;
        uint amtBMin;
    }

    function removeLiquidityInternal(
        address tokenA,
        address tokenB,
        address lp,
        WithdrawAmounts memory amt
    ) internal {
        // 1. Remove liquidity
        if (amt.amtLPWithdraw > 0) {
            router.removeLiquidity(
                tokenA,
                tokenB,
                amt.amtLPWithdraw,
                0,
                0,
                address(this),
                now
            );
        }

        // 2. Slippage control
        require(IERC20(tokenA).balanceOf(address(this)) >= amt.amtAMin);
        require(IERC20(tokenB).balanceOf(address(this)) >= amt.amtBMin);
        require(IERC20(lp).balanceOf(address(this)) >= 0);

        // 3. Refund leftover
        doRefundETH();
        doRefund(tokenA);
        doRefund(tokenB);
        doRefund(lp);
    }

    function addLiquidityWERC20(Amounts calldata amt) external payable virtual;
}
