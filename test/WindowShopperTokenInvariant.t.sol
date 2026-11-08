// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";

/// @notice Drives the token with random, bounded calls from a fixed set of actors and keeps an
///         independent model of every balance and allowance. Calls the model says must fail are
///         attempted too, and any that succeed, or that change state, are counted as violations.
/// @dev Handler reverts are discarded by forge's invariant runner, so the handler never asserts:
///      it records what it saw in ghost variables and the invariant functions check them.
contract TokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    WindowShopperToken public immutable token;
    address[] internal actors;
    /// @dev Every address that can ever hold tokens: the actors plus the token contract itself.
    address[] internal holders;

    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;

    /// @dev Total each spender has moved out of each owner through transferFrom.
    mapping(address => mapping(address => uint256)) public ghostPulled;
    /// @dev Total each owner has granted each spender (sum of finite approvals; max is infinite).
    mapping(address => mapping(address => uint256)) public ghostGranted;
    mapping(address => mapping(address => bool)) public ghostInfinite;

    uint256 public violations;
    string public lastViolation;

    uint256 public callsTransfer;
    uint256 public callsTransferFrom;
    uint256 public callsApprove;
    uint256 public callsExpectedFailures;

    constructor(WindowShopperToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            holders.push(actors_[i]);
        }
        holders.push(address(token_));
        modelBalance[actors_[0]] = SUPPLY;
    }

    // ------------------------------------------------------------------------------------------
    // Successful paths
    // ------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        amount = bound(amount, 0, modelBalance[from]);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) _violate("transfer returned false");
            modelBalance[from] -= amount;
            modelBalance[to] += amount;
            ++callsTransfer;
        } catch {
            _violate("valid transfer reverted");
        }
        _checkPair(from, to);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        else amount = bound(amount, 0, SUPPLY * 2);

        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) _violate("approve returned false");
            modelAllowance[owner][spender] = amount;
            if (amount == type(uint256).max) ghostInfinite[owner][spender] = true;
            else ghostGranted[owner][spender] += amount;
            ++callsApprove;
        } catch {
            _violate("valid approve reverted");
        }
        if (token.allowance(owner, spender) != modelAllowance[owner][spender]) _violate("allowance mismatch");
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 allowed = modelAllowance[from][spender];
        uint256 cap = allowed < modelBalance[from] ? allowed : modelBalance[from];
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            if (!ok) _violate("transferFrom returned false");
            modelBalance[from] -= amount;
            modelBalance[to] += amount;
            if (allowed != type(uint256).max) modelAllowance[from][spender] = allowed - amount;
            ghostPulled[from][spender] += amount;
            ++callsTransferFrom;
        } catch {
            _violate("valid transferFrom reverted");
        }
        _checkPair(from, to);
        if (token.allowance(from, spender) != modelAllowance[from][spender]) _violate("allowance mismatch");
    }

    // ------------------------------------------------------------------------------------------
    // Paths the model says must fail. Each must revert and leave every balance untouched.
    // ------------------------------------------------------------------------------------------

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 amount = modelBalance[from] + bound(excess, 1, SUPPLY);
        vm.prank(from);
        try token.transfer(to, amount) {
            _violate("transfer above balance succeeded");
        } catch (bytes memory reason) {
            _expectError(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, modelBalance[from], amount)
            );
        }
        _checkPair(from, to);
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, modelBalance[from]);
        vm.prank(from);
        try token.transfer(address(0), amount) {
            _violate("transfer to zero address succeeded");
        } catch (bytes memory reason) {
            _expectError(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        }
        _checkPair(from, from);
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 allowed = modelAllowance[from][spender];
        if (allowed == type(uint256).max) return; // an infinite allowance cannot be exceeded
        uint256 amount = allowed + bound(excess, 1, SUPPLY);
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            _violate("transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            _expectError(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        }
        _checkPair(from, to);
        if (token.allowance(from, spender) != allowed) _violate("failed transferFrom changed allowance");
    }

    function transferFromOverBalance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _holder(toSeed);
        uint256 allowed = modelAllowance[from][spender];
        uint256 amount = modelBalance[from] + bound(excess, 1, SUPPLY);
        if (amount > allowed) return; // the allowance check fires first; covered above
        vm.prank(spender);
        try token.transferFrom(from, to, amount) {
            _violate("transferFrom above owner balance succeeded");
        } catch (bytes memory reason) {
            _expectError(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, modelBalance[from], amount)
            );
        }
        _checkPair(from, to);
        if (token.allowance(from, spender) != allowed) _violate("failed transferFrom changed allowance");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            _violate("approve to zero spender succeeded");
        } catch (bytes memory reason) {
            _expectError(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
    }

    // ------------------------------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------------------------------

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _holder(uint256 seed) internal view returns (address) {
        return holders[seed % holders.length];
    }

    function _checkPair(address a, address b) internal {
        if (token.balanceOf(a) != modelBalance[a]) _violate("balance mismatch");
        if (token.balanceOf(b) != modelBalance[b]) _violate("balance mismatch");
    }

    function _expectError(bytes memory got, bytes memory want) internal {
        ++callsExpectedFailures;
        if (keccak256(got) != keccak256(want)) _violate("unexpected revert reason");
    }

    function _violate(string memory why) internal {
        ++violations;
        lastViolation = why;
    }
}

/// @notice Invariants over random call sequences: the supply is fixed, balances are conserved,
///         the token matches an independent model, and no spender moves more than it was granted.
contract WindowShopperTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    WindowShopperToken internal token;
    TokenHandler internal handler;

    function setUp() public {
        address[] memory actors = new address[](5);
        actors[0] = makeAddr("deployer");
        actors[1] = makeAddr("alice");
        actors[2] = makeAddr("bob");
        actors[3] = makeAddr("carol");
        actors[4] = makeAddr("dave");

        vm.prank(actors[0]);
        token = new WindowShopperToken();
        handler = new TokenHandler(token, actors);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        selectors[3] = TokenHandler.transferTooMuch.selector;
        selectors[4] = TokenHandler.transferToZero.selector;
        selectors[5] = TokenHandler.transferFromOverAllowance.selector;
        selectors[6] = TokenHandler.transferFromOverBalance.selector;
        selectors[7] = TokenHandler.approveZeroSpender.selector;
        selectors[8] = TokenHandler.transfer.selector; // weight transfers so balances spread out
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Guards against a vacuous run: every sequence must have exercised the token.
    function afterInvariant() public view {
        assertGt(
            handler.callsTransfer() + handler.callsTransferFrom() + handler.callsApprove()
                + handler.callsExpectedFailures(),
            0,
            "the handler never reached the token"
        );
    }

    /// forge-config: default.invariant.runs = 256
    function invariant_noHandlerViolations() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// forge-config: default.invariant.runs = 256
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 256
    function invariant_balancesSumToTotalSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.holderAt(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// forge-config: default.invariant.runs = 256
    function invariant_balancesMatchModel() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address h = handler.holderAt(i);
            assertEq(token.balanceOf(h), handler.modelBalance(h));
        }
    }

    /// forge-config: default.invariant.runs = 256
    function invariant_allowancesMatchModelAndPullsStayWithinGrants() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address owner = handler.actorAt(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.actorAt(j);
                assertEq(token.allowance(owner, spender), handler.modelAllowance(owner, spender));
                if (!handler.ghostInfinite(owner, spender)) {
                    assertLe(handler.ghostPulled(owner, spender), handler.ghostGranted(owner, spender));
                }
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    function invariant_tokenHoldsNoEtherAndSupplyNeverReturnsToZeroAddress() public view {
        assertEq(address(token).balance, 0);
        assertEq(token.balanceOf(address(0)), 0);
    }
}
