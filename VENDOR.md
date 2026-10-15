# Vendored dependencies

All dependency source files and their licenses are ordinary repository files.
No package installation, network access, or Git submodules are needed to build.

- OpenZeppelin Contracts **v5.0.2**, upstream `contracts/` and MIT license:
  https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.0.2
- Forge Standard Library **v1.9.7**, upstream `src/` and Apache/MIT licenses:
  https://github.com/foundry-rs/forge-std/releases/tag/v1.9.7

Foundry remappings are in `foundry.toml`. Solidity is pinned to **0.8.26**;
application pragmas accept **^0.8.24**. The compiler itself is supplied by the
Foundry environment and is not vendored.
