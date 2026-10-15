// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Independent test-only RLP encoder. Synthetic headers exercise parser boundaries.
library HeaderBuilder {
    function uintBytes(uint256 value) internal pure returns (bytes memory result) {
        uint256 length;
        for (uint256 n = value; n != 0; n >>= 8) {
            ++length;
        }
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[length - 1 - i] = bytes1(uint8(value >> (8 * i)));
        }
    }

    function stringRLP(bytes memory value) internal pure returns (bytes memory) {
        if (value.length == 1 && uint8(value[0]) < 0x80) return value;
        return bytes.concat(prefix(value.length, 0x80), value);
    }

    function prefix(uint256 length, uint8 base) internal pure returns (bytes memory) {
        if (length < 56) return abi.encodePacked(bytes1(uint8(length) + base));
        bytes memory size = uintBytes(length);
        return bytes.concat(abi.encodePacked(bytes1(base + 55 + uint8(size.length))), size);
    }

    function list(bytes[] memory values) internal pure returns (bytes memory) {
        bytes memory payload;
        for (uint256 i; i < values.length; ++i) {
            payload = bytes.concat(payload, stringRLP(values[i]));
        }
        return bytes.concat(prefix(payload.length, 0xc0), payload);
    }

    function fields(uint256 number, bytes32 randao, uint256 trailing) internal pure returns (bytes[] memory result) {
        result = new bytes[](14 + trailing);
        result[8] = uintBytes(number);
        result[13] = abi.encodePacked(randao);
        for (uint256 i = 14; i < result.length; ++i) {
            result[i] = uintBytes(i);
        }
    }

    function header(uint256 number, bytes32 randao, uint256 trailing) internal pure returns (bytes memory) {
        return list(fields(number, randao, trailing));
    }
}
