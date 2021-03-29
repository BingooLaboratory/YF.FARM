// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IStrategy.sol";

interface IYFPool {
    function add(
        bool _withUpdate,

        uint _allocYPoint,
        uint _allocUPoint,
        bool _allocHarvest,
        bool _allocBuyback,

        address _want,
        address _earned,
        IStrategy _strat
    ) external;

    function set(
        bool _withUpdate,
        uint _pid,

        uint _allocYPoint,
        uint _allocUPoint,
        bool _allocHarvest,
        bool _allocBuyback
    ) external;

    function pending(uint pid, address user) external view returns (uint r1_, uint r2_, uint r3_);

    function deposit(uint pid, uint amount) external;

    function withdraw(uint pid, uint amount) external;

    function emergencyWithdraw(uint pid) external;

    function transmit(address token_, uint _amount) external;
    function distributeHarvest(uint fee_, uint buyback_, uint harvest_) external;

    /// @dev Return the current executor (the owner of the current position).
    function EXECUTOR() external view returns (address);
}
