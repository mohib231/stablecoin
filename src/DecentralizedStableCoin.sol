// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20Burnable, ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountShouldBeGreaterThanZero();
    error DecentralizedStableCoin__MinterMustBeTheOwner();
    error DecentralizedStableCoin__BalanceMustBeGreaterThanAmount();
    error DecentralizedStableCoin__AmountNotMinted();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountShouldBeGreaterThanZero();
        }
        if (_to == address(0)) {
            revert DecentralizedStableCoin__MinterMustBeTheOwner();
        }
        _mint(_to, _amount);
        return true;
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountShouldBeGreaterThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin__BalanceMustBeGreaterThanAmount();
        }
        super.burn(_amount);
    }
}
