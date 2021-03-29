// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// For interacting with our own strategy
interface IStrategy {
    // Total want tokens managed by stratfegy
    function wantLockedTotal() external view returns (uint);

    // Sum of all shares of users to wantLockedTotal
    function sharesTotal() external view returns (uint);

    // Main want token compounding function
    function earn() external;

    // Transfer want tokens yfvaluts -> strategy
    function deposit(address _userAddress, uint _wantAmt) external returns (uint);

    // Transfer want tokens strategy -> yfvaluts
    function withdraw(address _userAddress, uint _wantAmt) external returns (uint);

    function inCaseTokensGetStuck(address _token, uint _amount, address _to) external;

    function farm() external;
    function pause() external;
    function unpause() external;

    // In case new vaults require functions without a timelock as well, hoping to avoid having multiple timelock contracts
    function noTimeLockFunc1() external;

    function noTimeLockFunc2() external;

    function noTimeLockFunc3() external;
}
