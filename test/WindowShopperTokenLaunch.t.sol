// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WindowShopperToken} from "../src/WindowShopperToken.sol";
import {DeployWindowShopperToken} from "../script/DeployWindowShopperToken.s.sol";

/// @dev Stands in for the launch factory: deploys the token through CREATE2 from raw creation code,
///      as `ProjectFactory.launchCustom` does, and then forwards the shares the launch moves.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(WindowShopperToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice The launch flows the token must carry exactly: deployment from creation code by a factory
///         that then holds the whole supply, the swarm's 10%, the pool's 70% and the requester's 20%
///         arriving whole, a claimant receiving whole, the supply never growing, and the runtime
///         containing no DELEGATECALL, CALLCODE or SELFDESTRUCT.
contract WindowShopperTokenLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 7_000;
    uint256 internal constant BPS = 10_000;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant POOL = address(0x9001);
    address internal constant REMAINDER_TO = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66;

    FactoryStandIn internal factory;
    WindowShopperToken internal token;

    function setUp() public {
        factory = new FactoryStandIn();
        address deployed = factory.deploy(type(WindowShopperToken).creationCode, bytes32(uint256(42)));
        token = WindowShopperToken(deployed);
    }

    function test_create2DeploymentMintsWholeSupplyToFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.decimals(), 18);
    }

    function test_create2AddressIsPredictable() public {
        bytes32 salt = bytes32(uint256(7));
        bytes32 codeHash = keccak256(type(WindowShopperToken).creationCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
        address actual = factory.deploy(type(WindowShopperToken).creationCode, salt);
        assertEq(actual, predicted);
        assertEq(WindowShopperToken(actual).balanceOf(address(factory)), SUPPLY);
    }

    function test_launchSharesArriveWholeAndSumToSupply() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        uint256 pool = (SUPPLY * POOL_BPS) / BPS;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertTrue(factory.move(token, POOL, pool));
        assertTrue(factory.move(token, REMAINDER_TO, remainder));

        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");
        assertEq(token.balanceOf(POOL), pool, "pool share arrived short");
        assertEq(token.balanceOf(REMAINDER_TO), remainder, "remainder arrived short");
        assertEq(token.balanceOf(address(factory)), 0, "factory kept something back");
        assertEq(swarm + pool + remainder, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY, "launch flows changed the supply");
    }

    function test_claimFromDistributorArrivesWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / BPS;
        factory.move(token, DISTRIBUTOR, swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
    }

    function test_factoryCannotMoveAHolderBalanceAfterwards() public {
        address holder = address(0x401D);
        factory.move(token, holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);
        vm.prank(address(factory));
        (bool ok,) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, holder, address(factory), 1));
        assertFalse(ok);
        assertEq(token.balanceOf(holder), held);
        vm.prank(holder);
        assertTrue(token.transfer(address(0x07E5), held / 2));
    }

    function test_supplyCannotGrow_fromFactoryOrStranger() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setMinter(address)",
            "initialize(address)"
        ];
        address attacker = address(0xBEEF);
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    /// @dev Scans reachable runtime code (as the launch floor does) for forbidden opcodes.
    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    function test_deployScriptFunctionMintsToCaller() public {
        DeployWindowShopperToken script = new DeployWindowShopperToken();
        WindowShopperToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        // The script contract is `msg.sender` of the creation, so it holds the supply.
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
        assertEq(deployed.name(), "IMDwindowshopper");
        assertEq(deployed.symbol(), "WWW");
    }
}
