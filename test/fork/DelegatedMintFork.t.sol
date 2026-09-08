// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { NFTCollection } from "../../src/NFTCollection.sol";
import { MockDrandOracle } from "../mocks/MockDrandOracle.sol";

/// @notice delegate.xyz v2 registry, write side. `checkDelegateForContract` is what NFTCollection reads;
///         the two delegate* setters here are what a holder calls (Path 1). Same shape as the on-chain ABI.
interface IDelegateRegistryV2 {
    function delegateContract(address to, address contract_, bytes32 rights, bool enable)
        external
        payable
        returns (bytes32);
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function checkDelegateForContract(address to, address from, address contract_, bytes32 rights)
        external
        view
        returns (bool);
}

/// @notice BOTH delegated-mint paths against the REAL delegate.xyz v2 registry on a Robinhood Chain fork.
///         The unit tests (test/NFTCollectionDelegated.t.sol) use a mock registry; this proves the flow
///         round-trips against the ACTUAL registry bytecode: vault A delegates hot wallet B (Path 1), then
///         B mints A's allocation (Path 2), with the cap keyed to A and passes landing in B. It also proves
///         the v2 ALL-scope hierarchy and revocation behave exactly as the contract assumes.
///
///         RH_RPC_URL selects the chain (defaults to RH mainnet; the registry is deployed identically on
///         mainnet and testnet). Skips cleanly if the RPC is unreachable, so it never reds a normal run.
contract DelegatedMintForkTest is Test {
    // canonical delegate.xyz v2 registry, same address on every chain it is deployed to
    address constant REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    bytes32 constant RIGHTS = bytes32(0); // "all rights"; matches the bytes32(0) NFTCollection passes
    uint256 constant PRICE = 0.001 ether;

    string rpc = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    NFTCollection nft;
    MockDrandOracle oracle;
    IDelegateRegistryV2 reg = IDelegateRegistryV2(REGISTRY);

    address vaultA = makeAddr("vaultA"); // allowlisted cold wallet
    address delegateB = makeAddr("delegateB"); // hot wallet that mints
    bytes32[] empty; // single-leaf allowlist root == leaf, so the proof is empty

    function _reachable() internal returns (bool) {
        try vm.rpc(rpc, "eth_blockNumber", "[]") returns (bytes memory) {
            return true;
        } catch {
            return false;
        }
    }

    function setUp() public {
        if (!_reachable()) {
            emit log("DelegatedMintFork: RH_RPC_URL unreachable, skipping (set a reachable Robinhood Chain RPC to run).");
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc); // latest is always served (avoids the pruning-node pinned-state failure)
        require(REGISTRY.code.length > 0, "delegate.xyz v2 registry is not deployed on this chain");

        oracle = new MockDrandOracle(block.timestamp, 3);
        nft = new NFTCollection(PRICE, address(oracle), 1 hours, address(0xBEEF), address(this));
        nft.setRecipients(address(this), makeAddr("seed"), makeAddr("team"));
        nft.setDelegateRegistry(REGISTRY); // wire the REAL registry, not a mock
        nft.setMintOpen(true);
        nft.setAllowlistRoot(keccak256(abi.encodePacked(vaultA))); // single-leaf allowlist = vaultA
        nft.openAllowlistMint(); // GTD window (cap 3), ALLOWLIST phase
    }

    // ── Path 1 (delegateContract, scoped) then Path 2 (delegatedAllowlistMint): passes to B, cap to A ──
    function test_bothPaths_scoped() public {
        vm.prank(vaultA);
        reg.delegateContract(delegateB, address(nft), RIGHTS, true);
        assertTrue(
            reg.checkDelegateForContract(delegateB, vaultA, address(nft), RIGHTS),
            "real registry honors the scoped delegation"
        );

        vm.deal(delegateB, PRICE * 3);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE * 3 }(3, empty, vaultA);

        assertEq(nft.balanceOf(delegateB), 3, "passes land in the delegate B");
        assertEq(nft.balanceOf(vaultA), 0, "vault A holds none");
        assertEq(nft.mintedBy(vaultA), 3, "allocation counted against the vault A");
        assertEq(nft.mintedBy(delegateB), 0, "not counted against the delegate");
    }

    // ── v2 is hierarchical: a broad delegate-ALL also satisfies the per-contract check ──
    function test_allScope_alsoWorks() public {
        vm.prank(vaultA);
        reg.delegateAll(delegateB, RIGHTS, true);
        assertTrue(
            reg.checkDelegateForContract(delegateB, vaultA, address(nft), RIGHTS),
            "ALL scope covers the mint contract"
        );
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
        assertEq(nft.balanceOf(delegateB), 1);
        assertEq(nft.mintedBy(vaultA), 1);
    }

    // ── no delegation on the real registry -> NotDelegated ──
    function test_noDelegation_reverts() public {
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotDelegated.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── revocation on the real registry stops the mint ──
    function test_revoke_reverts() public {
        vm.prank(vaultA);
        reg.delegateContract(delegateB, address(nft), RIGHTS, true);
        vm.deal(delegateB, PRICE * 2);
        vm.prank(delegateB);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA); // works while delegated
        vm.prank(vaultA);
        reg.delegateContract(delegateB, address(nft), RIGHTS, false); // revoke on the real registry
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotDelegated.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultA);
    }

    // ── a valid delegation for a NON-allowlisted vault still cannot mint ──
    function test_vaultNotAllowlisted_reverts() public {
        address vaultC = makeAddr("vaultC");
        vm.prank(vaultC);
        reg.delegateContract(delegateB, address(nft), RIGHTS, true);
        vm.deal(delegateB, PRICE);
        vm.prank(delegateB);
        vm.expectRevert(NFTCollection.NotAllowlisted.selector);
        nft.delegatedAllowlistMint{ value: PRICE }(1, empty, vaultC);
    }
}
