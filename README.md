# IMDwindowshopper (WWW)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Property | Value |
|---|---|
| Solidity contract | `WindowShopperToken` (`src/WindowShopperToken.sol`) |
| `name()` | `IMDwindowshopper` |
| `symbol()` | `WWW` |
| `decimals()` | `18` |
| `totalSupply()` | `1_000_000_000 * 10**18` = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, the whole supply to `msg.sender` (the deployer) |
| Constructor arguments | None |
| Owner / admin | None |
| Transfer fee, tax, burn, reflection | None |
| Upgradeability | None (no proxy, no `delegatecall`, no `selfdestruct`) |

## Behaviour

`WindowShopperToken` inherits OpenZeppelin v5.1.0 `ERC20` unchanged and adds nothing but the
one-time mint and a `SupplyMinted` event. In particular:

- **Supply is fixed.** There is no `mint`, `issue`, minter role or initializer. Nothing can increase
  `totalSupply()` after construction, from any caller.
- **Transfers are exact.** `transfer` and `transferFrom` move exactly `amount`. Every launch flow
  (factory to distributor, factory to pool, factory to the requester, distributor to claimant, pool
  swaps) arrives whole.
- **No privileged hand.** There is no owner, pause, blocklist, freeze, lock, seize or `burnFrom`.
  Only a holder, or a spender within the allowance that holder granted, can move the holder's
  balance. `transferFrom` spends only the allowance `from` granted to `msg.sender`.
- **No ether.** The contract has no `receive` or `fallback`; plain ether transfers revert.
- **Deployer-agnostic.** The constructor takes no arguments, makes no external calls and requires no
  pre-existing code, so it deploys on an empty chain and under CREATE2 from a factory. Whichever
  account creates it holds the entire supply.

## Launch assumptions

These are decided by the launch, not by this repository:

- The IMD factory deploys the token from its creation code via `launchCustom`; the factory is
  `msg.sender` of the constructor and so receives all 1,000,000,000 WWW.
- The factory forwards 10% of the supply to the launch's MerkleDistributor, seeds the Uniswap v4
  pool with 70% (`economics.poolBps = 7000`) paired with IMD
  (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, pool fee 12500, tick spacing 60), and sends the
  remaining 20% to `economics.remainderTo` (`0xee2aaa315cf7ed169f93148d30d24af9318dbb66`).
- The manifest step writes `launch.json` after acceptance; this repository intentionally contains
  none. Manifest values for the token: `contract = "WindowShopperToken"`, `name = "IMDwindowshopper"`,
  `symbol = "WWW"`, `decimals = 18`, `constructorArgs = []`,
  `totalSupply = "1000000000000000000000000000"`.
- The token needs no exemptions: it has no fee, so it does not take `$factory`, `$poolManager` or
  `$launchNumber` as constructor arguments.

## Deployment parameters

- **Compiler:** `solc = "0.8.26"`, optimizer on, 200 runs, `bytecode_hash = "none"` and
  `cbor_metadata = false`, so the built bytecode is reproducible and contains no metadata hash.
- **Constructor arguments:** none.
- **Constants** (in `src/WindowShopperToken.sol`): `NAME`, `SYMBOL`, `DECIMALS = 18`,
  `TOTAL_SUPPLY = 1_000_000_000 * 10**18`. There are no open numbers the brief left to choose.
- **Script:** `script/DeployWindowShopperToken.s.sol` is a reference deployment for reviewers and
  local testing. Its `deploy()` function is tested directly; `run()` only wraps it in a broadcast and
  reads no environment. It is not the launch path and is never broadcast by a task.

## After launch

There is nothing for an owner to set: the token has no owner and no configurable state.

Operational responsibilities that remain with the launch and the requester:

- **Explorer verification** of the deployed token source is the deployer's, using the pinned
  compiler settings above (`forge verify-contract` with `--compiler-version 0.8.26`,
  `--optimizer-runs 200`, no constructor arguments).
- **Supply custody.** After launch the factory holds nothing; the 20% remainder sits at
  `remainderTo`. Securing that wallet is the requester's responsibility. The token itself cannot
  recover, freeze or reassign tokens sent to a wrong address or to the token contract.
- **Independent review.** Tests passing is not a security audit. A separate adversarial review by an
  independent contributor precedes release, per the launch policy.

## Repository layout

```
foundry.toml                         compiler pins and profile (bytecode_hash = "none", no ffi, no fs access)
remappings.txt                       forge-std/ and @openzeppelin/contracts/ remappings
src/WindowShopperToken.sol           the token
script/DeployWindowShopperToken.s.sol reference deploy script
test/WindowShopperToken.t.sol        ERC-20 unit tests: success and failure paths, fuzz
test/WindowShopperTokenLaunch.t.sol  launch flows: CREATE2 by a factory, exact shares, no supply growth, opcode scan
lib/forge-std                        forge-std v1.9.7 (src + licences), vendored as plain files
lib/openzeppelin-contracts           OpenZeppelin Contracts v5.1.0, only the ERC20 subset, vendored as plain files
```

Dependencies are vendored as ordinary files (no git submodules) so the project builds offline.

## Verify

```
forge build
forge test
forge fmt --check
```

The fuzz tests were run with `FOUNDRY_FUZZ_SEED=0xc26cd3425d98be3da3d6e2a68e944340e190f815906fe31e971ccfd87146bd56`
as the verifier does. Tests read no environment variables and do not depend on the calling address,
so they pass in any order and in parallel.

## Security notes

Checked against the eth-security reference: no reentrancy surface (no external calls, no ether), no
oracle or price math, no decimals assumptions beyond the token's own 18, no `selfdestruct`,
`delegatecall` or unprotected initializer, no `abi.encodePacked` of dynamic values, no external
library calls (nothing to link). Slither was not available on this machine; the verifier runs it.
