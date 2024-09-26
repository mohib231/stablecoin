// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {Test, console} from "lib/forge-std/src/Test.sol";

contract TestDecentralizedStableCoin is Test {
    DecentralizedStableCoin decentralizedStableCoin;
    address user = makeAddr("user");

    function setUp() external returns (DecentralizedStableCoin) {
        vm.startBroadcast();
        decentralizedStableCoin = new DecentralizedStableCoin();
        decentralizedStableCoin.transferOwnership(user);
        vm.stopBroadcast();
        return decentralizedStableCoin;
    }

    function test_Name() public view {
        string memory name = "DecentralizedStableCoin";
        assertEq(keccak256(abi.encodePacked(name)), keccak256(abi.encodePacked(decentralizedStableCoin.name())));
    }

    function test_Symbol() public view {
        string memory symbol = "DSC";
        assertEq(keccak256(abi.encodePacked(symbol)), keccak256(abi.encodePacked(decentralizedStableCoin.symbol())));
    }

    function test_MintFunctionWithZeroAddress() public {
        uint256 amount = 100;
        vm.expectRevert();
        decentralizedStableCoin.mint(address(0), amount);
    }

    function test_MintFunctionWithZeroBalance() public {
        vm.prank(user);
        uint256 amount = 0;
        vm.expectRevert();
        decentralizedStableCoin.mint(user, amount);
    }

    function test_MintFunctionIsSuccessful() public {
        vm.prank(user);
        uint256 amount = 100;
        decentralizedStableCoin.mint(user, amount);
    }

    function test_burnFunctionWithAmountZero() public {
        vm.prank(user);
        uint256 amount = 0;
        vm.expectRevert();
        decentralizedStableCoin.burn(amount);
    }

    function test_burnFunctionWithAmountIsGreaterThanItsBalance() public {
        hoax(user, 100);
        vm.expectRevert();
        decentralizedStableCoin.burn(110);
    }

    function test_burnFunctionIsSuccessful() public {
        vm.prank(user);
        decentralizedStableCoin.mint(user, 1000);

        console.log(decentralizedStableCoin.balanceOf(user));
        assertEq(decentralizedStableCoin.balanceOf(user), 1000, "Minting failed");

        vm.prank(user);
        decentralizedStableCoin.burn(100);

        assertEq(decentralizedStableCoin.balanceOf(user), 900, "Burning failed");
    }

}
