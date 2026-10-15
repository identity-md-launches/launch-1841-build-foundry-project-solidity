// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OGClubFurniture} from "./OGClubFurniture.sol";
import {BlockHeader} from "./libraries/BlockHeader.sol";

/// @title OG Club Box
/// @notice Sell furniture boxes using an immutable season and a future block's authenticated prevRandao.
/// @dev No custody of purchase payments. Direct external calls are only to token and furniture.
contract OGClubBox is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Tier numbers are Common, Uncommon, Rare, Epic, Legendary (0 through 4).
    struct Entry {
        uint256 itemId;
        uint8 tier;
        uint256 weight;
        uint256 cap;
    }

    struct Season {
        uint256 price;
        uint256 opensAt;
        uint256 closesAt;
        uint256 burnBps;
        uint256 fallbackItem;
        bool closed;
        bool cancelled;
    }

    struct Purchase {
        address buyer;
        uint256 seasonId;
        uint256 count;
        uint256 targetBlock;
        bool opened;
    }

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    uint256 public constant TARGET_DELAY = 3;
    uint256 public constant REVEAL_WINDOW = 256;

    IERC20 public immutable token;
    OGClubFurniture public immutable furniture;
    address public vault;
    bool public paused;
    uint256 public seasonCount;
    uint256 public purchaseCount;

    mapping(uint256 seasonId => Season) private _seasons;
    mapping(uint256 seasonId => Entry[]) private _entries;
    mapping(uint256 seasonId => mapping(uint256 itemId => uint256 amount)) public minted;
    mapping(uint256 purchaseId => Purchase) public purchases;

    error InvalidAddress();
    error InvalidEntryCount();
    error InvalidSeasonParameters();
    error InvalidEntry(uint256 index);
    error DuplicateItem(uint256 itemId);
    error InvalidFallback();
    error WeightOverflow();
    error UnknownSeason(uint256 seasonId);
    error SeasonAlreadyClosed(uint256 seasonId);
    error SeasonAlreadyStarted(uint256 seasonId);
    error SalesUnavailable(uint256 seasonId);
    error BuyingPaused();
    error InvalidCount();
    error PaymentOverflow();
    error ShortTransfer(address recipient, uint256 expected, uint256 received);
    error UnknownPurchase(uint256 purchaseId);
    error AlreadyOpened(uint256 purchaseId);
    error TargetBlockNotPassed(uint256 targetBlock);
    error HeaderHashMismatch();
    error HeaderNumberMismatch(uint256 expected, uint256 actual);
    error NoAvailableItems();

    event SeasonCreated(
        uint256 indexed seasonId,
        uint256 price,
        uint256 opensAt,
        uint256 closesAt,
        uint256 burnBps,
        uint256 fallbackItem
    );
    event SeasonEntry(uint256 indexed seasonId, uint256 indexed itemId, uint8 tier, uint256 weight, uint256 cap);
    event SeasonClosed(uint256 indexed seasonId);
    event SeasonCancelled(uint256 indexed seasonId);
    event PausedSet(bool paused);
    event VaultSet(address indexed previousVault, address indexed newVault);
    event BoxesBought(
        uint256 indexed purchaseId,
        address indexed buyer,
        uint256 indexed seasonId,
        uint256 count,
        uint256 targetBlock,
        uint256 burnAmt,
        uint256 vaultAmt
    );
    event BoxOpened(
        uint256 indexed purchaseId, uint256 index, uint256 itemId, uint8 tier, bytes32 prevRandao, bool expired
    );

    /// @param token_ ERC-20 used for prices, in that token's smallest units.
    /// @param furniture_ Furniture contract which must authorize this box as a minter after deployment.
    /// @param vault_ Nonzero beneficiary of the unburned payment share.
    /// @param initialOwner Account allowed to create/stop seasons and manage sales settings.
    constructor(IERC20 token_, OGClubFurniture furniture_, address vault_, address initialOwner) Ownable(initialOwner) {
        if (address(token_) == address(0) || address(furniture_) == address(0)) revert InvalidAddress();
        token = token_;
        furniture = furniture_;
        _setVault(vault_);
    }

    /// @notice Create a season with permanent terms and at least one unlimited Common fallback.
    /// @dev IDs start at 1. Weight totals must fit uint256. Seasons may overlap.
    function createSeason(
        uint256 price,
        uint256 opensAt,
        uint256 closesAt,
        uint256 burnBps,
        uint256 fallbackItem,
        Entry[] calldata entries
    ) external onlyOwner returns (uint256 seasonId) {
        if (entries.length == 0 || entries.length > 32) revert InvalidEntryCount();
        if (price == 0 || opensAt >= closesAt || burnBps > BPS) revert InvalidSeasonParameters();
        uint256 totalWeight;
        bool validFallback;
        for (uint256 i; i < entries.length; ++i) {
            Entry calldata entry = entries[i];
            if (entry.tier > 4 || entry.weight == 0) revert InvalidEntry(i);
            if (entry.weight > type(uint256).max - totalWeight) revert WeightOverflow();
            totalWeight += entry.weight;
            for (uint256 j; j < i; ++j) {
                if (entry.itemId == entries[j].itemId) revert DuplicateItem(entry.itemId);
            }
            if (entry.itemId == fallbackItem && entry.cap == 0 && entry.tier == 0) validFallback = true;
        }
        if (!validFallback) revert InvalidFallback();

        seasonId = ++seasonCount;
        _seasons[seasonId] = Season(price, opensAt, closesAt, burnBps, fallbackItem, false, false);
        emit SeasonCreated(seasonId, price, opensAt, closesAt, burnBps, fallbackItem);
        for (uint256 i; i < entries.length; ++i) {
            _entries[seasonId].push(entries[i]);
            emit SeasonEntry(seasonId, entries[i].itemId, entries[i].tier, entries[i].weight, entries[i].cap);
        }
    }

    /// @notice Permanently stop this season's sales without preventing existing purchases from opening.
    function closeSeason(uint256 seasonId) external onlyOwner {
        Season storage season = _season(seasonId);
        if (season.closed) revert SeasonAlreadyClosed(seasonId);
        season.closed = true;
        emit SeasonClosed(seasonId);
    }

    /// @notice Cancel an unstarted, not-yet-closed season. Cancellation is permanent.
    function cancelSeason(uint256 seasonId) external onlyOwner {
        Season storage season = _season(seasonId);
        if (season.closed) revert SeasonAlreadyClosed(seasonId);
        if (block.timestamp >= season.opensAt) revert SeasonAlreadyStarted(seasonId);
        season.closed = true;
        season.cancelled = true;
        emit SeasonCancelled(seasonId);
    }

    /// @notice Pause or resume purchases; reveals remain permissionless.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    /// @notice Set the destination of future purchases' vault share.
    function setVault(address newVault) external onlyOwner {
        _setVault(newVault);
    }

    /// @notice Pay for 1–10 boxes and commit to a target three blocks in the future.
    /// @dev Both payment legs go directly from the buyer to their recipients. A revert is atomic.
    function buy(uint256 seasonId, uint256 count) external nonReentrant returns (uint256 purchaseId) {
        Season storage season = _season(seasonId);
        if (count == 0 || count > 10) revert InvalidCount();
        if (paused) revert BuyingPaused();
        if (season.closed || block.timestamp < season.opensAt || block.timestamp >= season.closesAt) {
            revert SalesUnavailable(seasonId);
        }
        if (season.price > type(uint256).max / count) revert PaymentOverflow();
        uint256 total = season.price * count;
        uint256 burnAmt = Math.mulDiv(total, season.burnBps, BPS);
        uint256 vaultAmt = total - burnAmt;
        address recipient = vault;
        uint256 targetBlock = block.number + TARGET_DELAY;
        purchaseId = ++purchaseCount;
        purchases[purchaseId] = Purchase(msg.sender, seasonId, count, targetBlock, false);

        _pay(BURN_ADDRESS, burnAmt);
        _pay(recipient, vaultAmt);
        emit BoxesBought(purchaseId, msg.sender, seasonId, count, targetBlock, burnAmt, vaultAmt);
    }

    /// @notice Open a purchase for its buyer using the target block's complete RLP header.
    /// @dev Expired purchases ignore the header and mint only the fallback. All accounting precedes the sole mint call.
    function open(uint256 purchaseId, bytes calldata header) external nonReentrant {
        Purchase memory purchase = _openable(purchaseId);
        bool expired = block.number - purchase.targetBlock > REVEAL_WINDOW;
        bytes32 prevRandao;
        if (!expired) {
            if (keccak256(header) != blockhash(purchase.targetBlock)) revert HeaderHashMismatch();
            uint256 number;
            (number, prevRandao) = BlockHeader.decode(header);
            if (number != purchase.targetBlock) revert HeaderNumberMismatch(purchase.targetBlock, number);
        }

        purchases[purchaseId].opened = true;
        (uint256[] memory ids, uint8[] memory tiers) = _roll(purchaseId, purchase, prevRandao, expired);
        uint256[] memory amounts = new uint256[](purchase.count);
        for (uint256 i; i < purchase.count; ++i) {
            ++minted[purchase.seasonId][ids[i]];
            amounts[i] = 1;
            emit BoxOpened(purchaseId, i, ids[i], tiers[i], prevRandao, expired);
        }
        furniture.mintBatch(purchase.buyer, ids, amounts);
    }

    /// @notice Predict an open using current caps and the supplied prevRandao (not authenticated by this view).
    /// @dev Same readiness checks and roll path as open. Expired previews ignore prevRandao.
    ///      Other opens can consume caps and change a later result; this view does not reserve items.
    function previewOpen(uint256 purchaseId, bytes32 prevRandao) external view returns (uint256[] memory itemIds) {
        Purchase memory purchase = _openable(purchaseId);
        (itemIds,) = _roll(purchaseId, purchase, prevRandao, block.number - purchase.targetBlock > REVEAL_WINDOW);
    }

    /// @notice Read a season's immutable terms and terminal sales flags.
    function getSeason(uint256 seasonId) external view returns (Season memory) {
        return _season(seasonId);
    }

    /// @notice Read the original entries in their original weighted-roll order.
    function getEntries(uint256 seasonId) external view returns (Entry[] memory) {
        _season(seasonId);
        return _entries[seasonId];
    }

    function _setVault(address newVault) private {
        if (newVault == address(0) || newVault == address(this)) revert InvalidAddress();
        emit VaultSet(vault, newVault);
        vault = newVault;
    }

    function _pay(address recipient, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(recipient);
        token.safeTransferFrom(msg.sender, recipient, amount);
        uint256 afterBalance = token.balanceOf(recipient);
        uint256 received = afterBalance >= beforeBalance ? afterBalance - beforeBalance : 0;
        if (received < amount) revert ShortTransfer(recipient, amount, received);
    }

    function _season(uint256 seasonId) private view returns (Season storage season) {
        if (seasonId == 0 || seasonId > seasonCount) revert UnknownSeason(seasonId);
        return _seasons[seasonId];
    }

    function _openable(uint256 purchaseId) private view returns (Purchase memory purchase) {
        purchase = purchases[purchaseId];
        if (purchase.buyer == address(0)) revert UnknownPurchase(purchaseId);
        if (purchase.opened) revert AlreadyOpened(purchaseId);
        if (block.number <= purchase.targetBlock) revert TargetBlockNotPassed(purchase.targetBlock);
    }

    /// @dev Simulate every mint locally so preview and execution share cap depletion and the ten-pack rule.
    function _roll(uint256 purchaseId, Purchase memory purchase, bytes32 prevRandao, bool expired)
        private
        view
        returns (uint256[] memory ids, uint8[] memory tiers)
    {
        ids = new uint256[](purchase.count);
        tiers = new uint8[](purchase.count);
        if (expired) {
            uint256 fallbackItem = _seasons[purchase.seasonId].fallbackItem;
            for (uint256 i; i < purchase.count; ++i) {
                ids[i] = fallbackItem;
            }
            return (ids, tiers);
        }

        Entry[] storage entries = _entries[purchase.seasonId];
        uint256[] memory counts = new uint256[](entries.length);
        for (uint256 j; j < entries.length; ++j) {
            counts[j] = minted[purchase.seasonId][entries[j].itemId];
        }
        for (uint256 i; i < purchase.count; ++i) {
            uint256 seed = uint256(keccak256(abi.encode(prevRandao, block.chainid, address(this), purchaseId, i)));
            uint256 picked = _pick(entries, counts, seed, purchase.count == 10 && i == 9);
            ids[i] = entries[picked].itemId;
            tiers[i] = entries[picked].tier;
            ++counts[picked];
        }
    }

    function _pick(Entry[] storage entries, uint256[] memory counts, uint256 seed, bool guarantee)
        private
        view
        returns (uint256)
    {
        uint256 totalWeight;
        uint256 rareWeight;
        for (uint256 j; j < entries.length; ++j) {
            Entry storage entry = entries[j];
            if (entry.cap == 0 || counts[j] < entry.cap) {
                totalWeight += entry.weight;
                if (entry.tier >= 2) rareWeight += entry.weight;
            }
        }
        bool rareOnly = guarantee && rareWeight != 0;
        uint256 roll = seed % (rareOnly ? rareWeight : totalWeight);
        for (uint256 j; j < entries.length; ++j) {
            Entry storage entry = entries[j];
            if ((entry.cap == 0 || counts[j] < entry.cap) && (!rareOnly || entry.tier >= 2)) {
                if (roll < entry.weight) return j;
                roll -= entry.weight;
            }
        }
        revert NoAvailableItems(); // Unreachable: the unlimited fallback keeps totalWeight positive.
    }
}
