// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock OG
/// @notice Test/testnet-only, 18-decimal payment token with unrestricted minting.
/// @dev The initial trillion-token supply is not a cap. Never use this mock for production payments.
contract MockOG is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000_000 * 10 ** 18;

    /// @param initialRecipient Explicit recipient of the entire initial supply.
    constructor(address initialRecipient) ERC20("Mock OG", "mockog") {
        _mint(initialRecipient, INITIAL_SUPPLY);
    }

    /// @notice Mint arbitrary test funds. Intentionally open to everyone.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
