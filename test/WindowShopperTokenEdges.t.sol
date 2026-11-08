// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

/// @notice Edge cases the main unit suite does not pin: zero amounts against zero allowances,
///         the zero address as a sender, events on allowance spending, and fuzzed failure paths.
contract WindowShopperTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    WindowShopperToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new WindowShopperToken();
    }

    function test_transferZeroToZeroAddressStillReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferFromZeroAddressRevertsEvenForZeroAmount() public {
        // A zero amount passes the (zero) allowance check; spending it re-approves for the zero
        // address, which OpenZeppelin rejects before the transfer's own sender check.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
    }

    function test_transferFromZeroAddressWithInfiniteAllowanceRevertsAsInvalidSender() public {
        // Give the zero address an infinite allowance to alice (impossible on chain) so the allowance
        // step is skipped and the sender check itself is reached.
        vm.store(
            address(token),
            keccak256(abi.encode(alice, keccak256(abi.encode(address(0), uint256(1))))),
            bytes32(type(uint256).max)
        );
        assertEq(token.allowance(address(0), alice), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), bob, 0);
    }

    function test_transferFromZeroAddressWithAmountRevertsOnAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), bob, 1);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceedsAndMovesNothing() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 0);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_spendingFiniteAllowanceEmitsNoApproval() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 4 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "only Transfer is emitted");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(token.allowance(deployer, alice), 6 ether);
    }

    function test_approveSelfAndZeroValue() public {
        vm.startPrank(alice);
        assertTrue(token.approve(alice, 0));
        assertTrue(token.approve(bob, 0));
        vm.stopPrank();
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_revokedAllowanceCannotBeSpent() public {
        vm.startPrank(deployer);
        token.approve(alice, 10 ether);
        token.approve(alice, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_maxMinusOneAllowanceIsDecremented() public {
        uint256 almost = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(alice, almost);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), almost - 1);
    }

    function test_transferToTokenContractIsAcceptedAndStuck() public {
        // Documented behaviour: the token has no recovery path, so tokens sent to it stay there.
        vm.prank(deployer);
        token.transfer(address(token), 1 ether);
        assertEq(token.balanceOf(address(token)), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveStoresAnyValue(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, spender, amount);
        vm.prank(alice);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(alice, spender), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromOverAllowanceRevertsAndChangesNothing(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, amount)
        );
        token.transferFrom(deployer, bob, amount);
        assertEq(token.allowance(deployer, alice), allowed);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromOverBalanceKeepsAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, type(uint256).max - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, bob), type(uint256).max - 1);
        assertEq(token.balanceOf(alice), held);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitTransfersConserveSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.transfer(alice, a);
        token.transfer(bob, b);
        vm.stopPrank();
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }
}
