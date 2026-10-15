// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title BlockHeader
/// @notice Read the block number and prevRandao from an RLP execution header.
/// @dev Callers must authenticate the complete header against blockhash before trusting these fields.
library BlockHeader {
    error InvalidRLP();
    error InvalidHeaderFields();

    /// @notice Decode zero-indexed fields 8 (number) and 13 (mixHash/prevRandao).
    /// @dev Accept any number of trailing fields, validating their outer RLP boundaries.
    ///      No fork-specific header length is assumed. All routines are internal and inlined.
    function decode(bytes calldata header) internal pure returns (uint256 blockNumber, bytes32 prevRandao) {
        (uint256 cursor,, uint256 end, bool isList) = _item(header, 0, header.length);
        if (!isList || end != header.length) revert InvalidRLP();
        uint256 field;
        while (cursor < end) {
            (uint256 start, uint256 size, uint256 next, bool list) = _item(header, cursor, end);
            if (field == 8) {
                if (list || size > 32) revert InvalidHeaderFields();
                // Integers use the shortest big-endian representation; zero is the empty string.
                if (size != 0) {
                    if (header[start] == 0) revert InvalidHeaderFields();
                    assembly ("memory-safe") {
                        blockNumber := shr(mul(sub(32, size), 8), calldataload(add(header.offset, start)))
                    }
                }
            } else if (field == 13) {
                if (list || size != 32) revert InvalidHeaderFields();
                assembly ("memory-safe") {
                    prevRandao := calldataload(add(header.offset, start))
                }
            }
            cursor = next;
            ++field;
        }
        if (field < 14) revert InvalidHeaderFields();
    }

    /// @dev Parse one canonical RLP item's prefix without reading outside its enclosing list.
    function _item(bytes calldata data, uint256 pos, uint256 end)
        private
        pure
        returns (uint256 start, uint256 size, uint256 next, bool list)
    {
        if (pos >= end) revert InvalidRLP();
        uint8 prefix = uint8(data[pos]);
        if (prefix < 0x80) return (pos, 1, pos + 1, false);

        list = prefix >= 0xc0;
        uint8 shortBase = list ? 0xc0 : 0x80;
        uint8 longBase = list ? 0xf7 : 0xb7;
        start = pos + 1;
        if (prefix <= longBase) {
            size = prefix - shortBase;
        } else {
            uint256 lengthBytes = prefix - longBase;
            if (lengthBytes > end - start || data[start] == 0) revert InvalidRLP();
            for (uint256 i; i < lengthBytes; ++i) {
                size = (size << 8) | uint8(data[start + i]);
            }
            if (size < 56) revert InvalidRLP();
            start += lengthBytes;
        }
        if (size > end - start) revert InvalidRLP();
        if (!list && size == 1 && uint8(data[start]) < 0x80) revert InvalidRLP();
        next = start + size;
    }
}
