// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

/// @notice Unit tests for the token's ERC-20 behaviour: metadata, the one-time mint, transfers,
///         allowances, and every failure path the standard defines.
contract WindowShopperTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    WindowShopperToken internal token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed recipient, uint256 amount);

    function setUp() public {
        vm.prank(deployer);
        token = new WindowShopperToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and the constructor mint
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "IMDwindowshopper");
        assertEq(token.symbol(), "WWW");
        assertEq(token.decimals(), 18);
        assertEq(token.DECIMALS(), 18);
    }

    function test_totalSupplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsTransferFromZeroAndSupplyMinted() public {
        address creator = makeAddr("creator");
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), creator, SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit SupplyMinted(creator, SUPPLY);
        vm.prank(creator);
        new WindowShopperToken();
    }

    function test_deployerIsWhoeverCreatesIt_contractDeployerHoldsSupply() public {
        // When a contract (such as a factory) deploys the token, that contract receives the supply.
        TokenCreator creator = new TokenCreator();
        WindowShopperToken created = creator.create();
        assertEq(created.balanceOf(address(creator)), SUPPLY);
        assertEq(created.balanceOf(address(this)), 0);
        assertEq(created.totalSupply(), SUPPLY);
    }

    function test_constructorHasNoArguments_rawCreationCodeDeploys() public {
        // Deploying the raw creation code with nothing appended must succeed, and the creator gets the supply.
        bytes memory creation = type(WindowShopperToken).creationCode;
        assertGt(creation.length, 0);
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(creation, 32), mload(creation))
        }
        assertTrue(deployed != address(0), "raw creation code failed to deploy");
        assertEq(WindowShopperToken(deployed).balanceOf(address(this)), SUPPLY);
        assertEq(WindowShopperToken(deployed).totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 1_000 ether);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 500 ether);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 500 ether));
        assertEq(token.balanceOf(alice), 500 ether);
    }

    function test_chainedTransfersArriveWholeAndConserveSupply() public {
        vm.prank(deployer);
        token.transfer(alice, 300 ether);
        vm.prank(alice);
        token.transfer(bob, 200 ether);
        vm.prank(bob);
        token.transfer(carol, 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(carol), 100 ether);
        assertEq(token.balanceOf(deployer) + 300 ether, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupplyAndArrivesWhole(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transfer(bob, 10 ether + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances and transferFrom: success
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 50 ether);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 50 ether));
        assertEq(token.allowance(deployer, alice), 50 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 50 ether);
        token.approve(alice, 5 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 5 ether);
    }

    function test_transferFromSpendsAllowanceAndMovesTokens() public {
        vm.prank(deployer);
        token.approve(alice, 50 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 20 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 20 ether));
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 20 ether);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(deployer, alice), 30 ether);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(alice, 20 ether);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 20 ether);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 20 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 20 ether);
    }

    function test_holderCanTransferFromItself_withSelfApproval() public {
        vm.startPrank(deployer);
        token.approve(deployer, 1 ether);
        assertTrue(token.transferFrom(deployer, alice, 1 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 1 ether);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowanceAmt, uint256 spend) public {
        allowanceAmt = bound(allowanceAmt, 0, SUPPLY);
        spend = bound(spend, 0, allowanceAmt);
        vm.prank(deployer);
        token.approve(alice, allowanceAmt);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, spend));
        assertEq(token.balanceOf(bob), spend);
        assertEq(token.allowance(deployer, alice), allowanceAmt - spend);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances and transferFrom: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferFromWithoutAllowanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromAboveAllowanceReverts() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 10 ether, 10 ether + 1)
        );
        token.transferFrom(deployer, bob, 10 ether + 1);
    }

    function test_transferFromAboveOwnerBalanceReverts() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        token.transferFrom(alice, carol, 6 ether);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1 ether);
    }

    function test_allowanceIsPerSpender_otherSpenderCannotUseIt() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1 ether));
        token.transferFrom(deployer, bob, 1 ether);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Nothing privileged exists: no mint, no admin, no freeze, no owner
    // ---------------------------------------------------------------------------------------------

    function test_noMintOrAdminSelectorIsCallable() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "upgradeTo(address)"
        ];
        address[2] memory callers = [deployer, alice];
        for (uint256 c = 0; c < callers.length; c++) {
            for (uint256 i = 0; i < signatures.length; i++) {
                bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_deployerHasNoPowerOverOtherHolders() public {
        vm.prank(deployer);
        token.transfer(alice, 100 ether);
        // The deployer cannot pull tokens back without an allowance.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1 ether));
        token.transferFrom(alice, deployer, 1 ether);
        // And alice remains free to move her tokens.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100 ether));
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_supportsIERC20Interface() public view {
        IERC20 erc20 = IERC20(address(token));
        assertEq(erc20.totalSupply(), SUPPLY);
        assertEq(erc20.balanceOf(deployer), SUPPLY);
    }

    function test_contractRejectsPlainEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    function test_unknownSelectorReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
    }
}

/// @dev Helper: a contract that creates the token, standing in for a factory.
contract TokenCreator {
    function create() external returns (WindowShopperToken) {
        return new WindowShopperToken();
    }
}
