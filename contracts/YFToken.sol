// SPDX-License-Identifier: MIT
pragma solidity >=0.6.12 <0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IYFToken.sol";

contract YFToken is Ownable, ERC20("YF Vaults Token", "YFT"), IYFToken {
    function mint(address _to, uint256 _amount) public override onlyOwner {
        _mint(_to, _amount);
    }
}
