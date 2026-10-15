// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title OG Club Furniture
/// @notice ERC-1155 furniture with designated minters, freezable metadata and bounded royalties.
/// @dev Ownership provides no transfer approval, confiscation or burn privilege.
contract OGClubFurniture is ERC1155, ERC1155Supply, ERC2981, Ownable2Step {
    string public constant name = "OG Club Furniture";
    string public constant symbol = "OGFURNI";
    uint96 public constant MAX_ROYALTY_BPS = 1000;

    string public baseURI;
    bool public metadataFrozen;
    mapping(address minter => bool allowed) public minters;

    error ZeroAddress();
    error NotMinter(address caller);
    error MetadataFrozen();
    error RoyaltyTooHigh(uint96 bps);

    event MinterSet(address indexed minter, bool allowed);
    event BaseURISet(string baseURI);
    event MetadataPermanentlyFrozen(string baseURI);
    event RoyaltySet(address indexed receiver, uint96 bps);

    /// @param initialOwner The account that controls minters, metadata and royalties.
    /// @param royaltyReceiver Initial royalty beneficiary (500 basis points).
    constructor(address initialOwner, address royaltyReceiver) ERC1155("") Ownable(initialOwner) {
        if (royaltyReceiver == address(0)) revert ZeroAddress();
        _setDefaultRoyalty(royaltyReceiver, 500);
        emit RoyaltySet(royaltyReceiver, 500);
    }

    /// @notice Authorize or revoke an account's ability to mint furniture.
    function setMinter(address minter, bool allowed) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        minters[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    /// @notice Mint piece IDs and quantities; only an explicitly authorized minter may call.
    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        if (!minters[msg.sender]) revert NotMinter(msg.sender);
        _mintBatch(to, ids, amounts, "");
    }

    /// @notice Set the metadata prefix, including any desired trailing slash, until frozen.
    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        baseURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    /// @notice Permanently prevent further changes to the metadata prefix.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataFrozen();
        metadataFrozen = true;
        emit MetadataPermanentlyFrozen(baseURI);
    }

    /// @notice Change the default royalty receiver and rate, up to 10%.
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh(bps);
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltySet(receiver, bps);
    }

    /// @notice Return baseURI + decimal piece ID + ".json", including for unminted IDs.
    function uri(uint256 id) public view override returns (string memory) {
        return string.concat(baseURI, Strings.toString(id), ".json");
    }

    /// @inheritdoc ERC1155
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Keep ERC-1155 balances and supply accounting on the same update path.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts)
        internal
        override(ERC1155, ERC1155Supply)
    {
        super._update(from, to, ids, amounts);
    }
}
