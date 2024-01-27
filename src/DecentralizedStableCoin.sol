// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    constructor() ERC20("DecentralisedStableCoin", "DSC") Ownable(msg.sender) {}

    error DecentralisedStableCoin_MustBeMoreThanZero();
    error DecentralisedStableCoin_BurnAmountExceedBalance();
    error DecentralisedStableCoin_NotWithZero();

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert DecentralisedStableCoin_MustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert DecentralisedStableCoin_BurnAmountExceedBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralisedStableCoin_NotWithZero();
        }
        if (_amount <= 0) {
            revert DecentralisedStableCoin_MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
