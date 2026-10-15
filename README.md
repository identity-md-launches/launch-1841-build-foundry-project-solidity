# OG Club furniture and boxes

This is a Foundry project for two non-upgradeable application contracts. It does
not deploy anything as part of a build or test. Solidity is pinned to 0.8.26, the
source accepts ^0.8.24, and OpenZeppelin Contracts 5.0.2 and forge-std 1.9.7 are
vendored as ordinary files. See [VENDOR.md](VENDOR.md) for versions and licenses.

`OGClubFurniture` is the ERC-1155 collection, named **OG Club Furniture**, symbol
**OGFURNI**. A token ID is a furniture piece ID. It tracks supply per ID and across
the collection, and reports ERC-2981 royalties.

`OGClubBox` sells boxes using an ERC-20. Season IDs and purchase IDs start at 1.
An item ID can be zero. Several seasons can sell at the same time.

## How a box is decided

1. The owner creates a season with a price, opening and closing timestamps, a
   burn percentage, a Common fallback piece, and 1–32 distinct entries. Each entry
   has an item ID, tier, positive weight and cap. Tiers 0–4 mean Common, Uncommon,
   Rare, Epic and Legendary. A zero cap means unlimited. The fallback must be an
   unlimited Common entry.
2. A buyer approves the box contract to spend the payment token and calls
   `buy(seasonId, count)`, with 1–10 boxes. Sales start at `opensAt` inclusive and
   end at `closesAt` exclusive. The purchase commits to `block.number + 3` and
   records the buyer and count. There is no buyer-supplied secret or seed.
3. After that target block, anyone can submit its full RLP execution header to
   `open(purchaseId, header)`. The contract checks that its Keccak hash equals
   `blockhash(targetBlock)`, decodes field 8 as the target number, and reads field
   13, `mixHash`, as **prevRandao**. Trailing fields are accepted, including those
   added by Shanghai, Cancun and Prague. The header hash authenticates the data;
   it is not used as the random seed.
4. For zero-based box index `i`, the seed is exactly
   `keccak256(abi.encode(prevRandao, block.chainid, address(this), purchaseId, i))`.
   The contract takes this number modulo the total available weight, then walks
   entries in their original order. Block hash, timestamp, coinbase and extraData
   do not enter the seed. The block where `open` runs does not supply randomness.
5. The selected entries are counted and minted to the recorded buyer in one
   `mintBatch` call. The purchase is marked opened and caps are updated before
   that call. Both `buy` and `open` have a shared reentrancy guard. A rejected
   receiver callback reverts the entire opening, which can then be retried.

This assumes an Ethereum proof-of-stake chain with Ethereum's execution-header
and prevRandao semantics. It is not a VRF. **The validator proposing the block
before the target can withhold it to re-roll once, losing its block reward.**
Colluding proposers, censorship and chain reorganizations remain consensus-level
risks; a three-block commitment is not a finality guarantee. The field definition
and withholding limitation are described in
[EIP-4399](https://eips.ethereum.org/EIPS/eip-4399).

## Expiry, ten-packs and caps

Opening is allowed only when `block.number > targetBlock`. The normal reveal
window includes `targetBlock + 256`. Starting at `targetBlock + 257`, the header is
ignored and **every box becomes the season's fallback piece**. An expired reveal
emits a zero prevRandao and `expired = true`. Expiry gives no new random roll and
overrides the ten-pack guarantee. There is no refund or cancellation of a paid
purchase. Anyone may pay the gas to open for the buyer, even after sales close or
while buying is paused.

For a live ten-pack, index 9 rolls only among available Rare, Epic and Legendary
entries, using their relative weights. If none remains at that moment, it uses
the ordinary roll. The first nine boxes may consume the last rare entries.
Smaller purchases have no tier guarantee.

Each pick updates the simulated availability before the next pick. A sold-out
entry has no weight and cannot roll again. Caps are **per season and per item**,
not global collection limits. Other seasons or authorized furniture minters may
mint the same piece ID. Weights describe current eligible entries, not permanent
odds: selling out a piece changes later odds. Opening order can therefore change
results when caps apply.

`previewOpen(purchaseId, prevRandao)` uses the same roll function and cap accounting
as `open`. It requires an existing, unopened purchase past its target block. It
does not authenticate the supplied prevRandao, reserve pieces or change state.
For a live purchase, supply the actual target header's mixHash. Its result matches
an immediate opening against the same state; other openings can consume caps in
between. After expiry, preview ignores the supplied value and returns fallbacks.

## Payments

Prices use the payment token's smallest units; the box does not assume a decimal
count. For each purchase:

```text
total    = price * count
burnAmt  = floor(total * burnBps / 10000)
vaultAmt = total - burnAmt
```

SafeERC20 transfers each nonzero share directly from the buyer to its recipient.
The burn recipient is `0x000000000000000000000000000000000000dEaD`. This is a
transfer to the burn address, not an ERC-20 supply-reduction call. Rounding goes to
the vault. Recipient balances must increase by at least the amount sent on each
leg; otherwise the whole purchase reverts, including any first transfer. Tokens
with missing return values are supported; false-returning and fee-on-transfer
payments are rejected. Use an ordinary, trusted, non-rebasing ERC-20. A token
that lies about balances is outside that assumption.

Successful purchases leave the box's token balance unchanged at zero. The vault
cannot be the box itself. As with any address, someone can send it unsolicited
ERC-20 tokens; the box cannot prevent that and has no recovery/sweep function.
A buyer who is also a payment recipient cannot satisfy the net-receipt check for
a nonzero self-transfer, so that purchase reverts. A zero-value leg is skipped.

## What the owners can and cannot do

Both applications use Ownable2Step. `transferOwnership` nominates a successor;
the successor must call `acceptOwnership` on each contract. Nominating zero
cancels a pending transfer. `renounceOwnership` permanently removes owner powers,
without clearing minter authorizations or undoing a paused state.

The box owner can create new seasons, irreversibly close their sales, or cancel
an unstarted season. Both closing and cancellation are terminal; a closed season
cannot subsequently be cancelled. Cancellation must occur strictly before
`opensAt`, when it has no purchases. The owner can also pause/resume purchases
and change the vault for future purchases. A season's percentage split stays
fixed, but its vault recipient follows the current vault setting.

The box owner cannot edit an existing season's price, window, entries, tiers,
weights, caps, fallback or split; reopen a closed season; replace the token or
furniture contract; change a purchase's target or recipient; choose a reveal
seed; stop `open` through the buying pause; or withdraw payment tokens. There are
no proxies or upgrade paths.

The furniture owner chooses authorized minters, can update the metadata prefix
until `freezeMetadata()`, and can set a royalty receiver and rate from 0 through
1000 basis points. Initial royalties are 500 basis points. Royalties are a
standard signal to marketplaces, not an enforced transfer charge. Metadata is
`baseURI + decimal itemId + ".json"`; include the desired trailing slash in the
prefix. Freezing metadata is permanent and does not freeze royalties or minters.

Ownership itself grants **no ability to move, burn or confiscate anyone's
furniture**. Holders and operators they approve retain standard ERC-1155 transfer
rights. There is no public burn function. The owner can authorize itself or
others to mint new tokens. It can revoke the box's minter authorization, which
would cause openings to revert until restored. Maintaining that permission is
an operational responsibility of the furniture owner.

## Deployment parameters and steps

No deployment was performed for this assignment. Constructors are nonpayable,
use static address arguments only, and do not call or require code at dependency
addresses. The deployer must verify the configured contracts on the intended
chain before enabling sales.

| Contract | Constructor parameters |
| --- | --- |
| `OGClubFurniture` | `initialOwner`, `royaltyReceiver` (both nonzero) |
| `OGClubBox` | `IERC20 token`, `OGClubFurniture furniture`, `vault`, `initialOwner` (all nonzero) |
| `MockOG` | `initialRecipient` of its initial test supply |

`script/Deploy.s.sol` reads **TOKEN**, **VAULT**, and **OWNER** from the operator's
environment. It creates furniture first, then the box. It uses OWNER as the
initial royalty receiver, a documented script choice that the furniture owner
can later change. It does not deploy a mock token or create a season. No private
key is read by the script. The eventual deployer supplies their signer through
their own Foundry invocation. `deploy(token, vault, owner)` is also callable
directly for parameterized local tests, without environment variables.

After deployment, the furniture owner must:

1. Call `furniture.setMinter(box, true)` with the confirmed box address.
2. Call `furniture.setBaseURI(...)` with the published metadata prefix. Check the
   files, then optionally call `freezeMetadata()`.

The box owner then creates seasons with the intended prices, windows, entries
and fallback. Confirm token allowances, recipient balances and mint permissions
before opening sales. Keep the collection's box minter permission enabled while
purchases remain unopened. Monitor `BoxesBought`, obtain headers and submit
reveals within the 256-block window. Buyers or independent relayers can do this;
there is no privileged opener or built-in keeper.

To prepare a header, fetch the target execution block with
`eth_getBlockByNumber` and encode its header fields in consensus order. The
standard-library-only helper accepts a block JSON object or JSON-RPC response:

```sh
python3 script/encode_header.py target-block.json
```

It supports execution headers through Prague. Check `cast keccak` of its output
against the block's published hash before passing the hex bytes to `open`.
Future forks that append header fields may require updating this off-chain
encoder; the contract accepts additional trailing fields already. Use the block
header itself, not the whole block or JSON encoding. A contract buyer must accept
ERC-1155 single and batch receiver callbacks to receive its furniture.

`getSeason(id)` and `getEntries(id)` expose season terms. `minted(seasonId,itemId)`
and `purchases(id)` expose accounting. Index `SeasonCreated`, `SeasonEntry`,
`BoxesBought` and `BoxOpened`; no per-user purchase arrays are stored. `BoxOpened`
includes purchase ID, zero-based index, piece ID, tier, prevRandao and expiry flag.
Administrative changes and ownership handovers also emit events.

`src/mocks/MockOG.sol` is **tests/testnets only**. Its symbol is **mockog**, it has
18 decimals, and construction mints **1,000,000,000,000 tokens** to the explicit
recipient. `mint` is public and unrestricted, so that initial supply is not a
maximum. The application deployment script expects an already chosen token.

## Local checks

With Foundry and Solidity 0.8.26 available, no dependency download is needed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd128ae280d16b8fe9fae2867fece2294232031c7e2780fa9c5d34bf71f39fb9d forge test
forge fmt --check
```

Tests use local mocks, `vm.roll`, and `vm.setBlockhash`; no RPC, environment reads,
filesystem permissions, or FFI are required. Real mainnet headers from Shanghai,
Cancun and Prague are embedded, with their original published fields and hashes
under [test/fixtures](test/fixtures/SOURCES.md). The suite covers payment splits,
malformed headers, all sale/reveal boundaries, access control, ownership, caps,
ten-packs, callback rollback and reentrancy. A statistical test samples 20,000
prevRandao values derived from fuzz entropy and checks each no-cap frequency
within one percentage point of its weight share. It suspends gas metering only
for those independent view queries. Stateful invariants check custody, payment
conservation, caps, supply, one-time opening and preview/open equality.

These local checks are not an independent security audit. A separate adversarial
review and verification of deployment parameters remain release responsibilities.
