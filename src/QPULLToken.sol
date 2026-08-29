// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title  QPULLToken
/// @notice A clean, fixed-supply, OWNERLESS ERC-20. That is the whole contract — deliberately.
///
///         The 4% trade tax, the first-hour NFT-holder gate, and the game-registry notifications
///         that used to live in this token's `_update` now live in QpullTaxHook, attached to the
///         canonical QPULL/WETH Uniswap-V4 pool (audit H-2): a transfer-tax token is STRUCTURALLY
///         INCOMPATIBLE with V4's flash accounting — skimming transfers breaks `settle()`
///         (CurrencyNotSettled) for every router that touches the token. Moving the tax into the
///         pool's own hook taxes actual trades, settles inside the locked context, and leaves plain
///         transfers (wallets, vaults, claims) untouched.
///
///         Security consequences of the strip, all deliberate:
///           - no owner: nothing to renounce, no launch-only exemptions to forget to revoke
///             (closes audit M-9), no wiring setters to misuse (closes M-13);
///           - no transfer hooks: no reentrancy surface, no way for the money token to brick
///             any settlement path, DEX or otherwise;
///           - fixed supply, minted once to the deployer, who seeds the canonical pool per the
///             launch runbook. No mint, no burn, no pause, no blocklist.
contract QPULLToken is ERC20 {
    constructor(uint256 initialSupply, address recipient) ERC20("QPULL", "QPULL") {
        _mint(recipient, initialSupply);
    }
}
