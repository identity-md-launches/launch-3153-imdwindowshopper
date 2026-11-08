// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMDwindowshopper (WWW)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 WWW (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). Nothing can mint afterwards.
/// @dev Deliberately minimal:
///      - no owner, admin, pauser or minter role of any kind;
///      - no fee, tax, burn or reflection on transfer: every transfer moves exactly `amount`;
///      - no blocklist, freeze, lock or seize path: only a holder (or its approved spender,
///        within the allowance it granted) can move that holder's balance;
///      - no upgradeability, no `delegatecall`, no `selfdestruct`;
///      - no constructor arguments and no external calls in the constructor, so it deploys on an
///        empty chain and under CREATE2 from a factory, which then holds the entire supply.
///      Behaviour is OpenZeppelin v5.1.0 `ERC20` unchanged. `transferFrom` spends only the
///      allowance `from` granted to `msg.sender`, so no account can move another's tokens without
///      that account's explicit approval.
contract WindowShopperToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string private constant NAME = "IMDwindowshopper";
    /// @notice Token symbol returned by `symbol()`.
    string private constant SYMBOL = "WWW";
    /// @notice Decimals returned by `decimals()` (the ERC20 default).
    uint8 public constant DECIMALS = 18;
    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Emitted exactly once, when the constructor mints the whole supply to the deployer.
    /// @param recipient The deployer (`msg.sender` of the creation), which receives the supply.
    /// @param amount The amount minted, always `TOTAL_SUPPLY`.
    event SupplyMinted(address indexed recipient, uint256 amount);

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. Takes no arguments and makes no external calls.
    constructor() ERC20(NAME, SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }
}
