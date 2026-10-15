// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BoxTestBase} from "./helpers/BoxTestBase.sol";
import {OGClubBox} from "../src/OGClubBox.sol";

contract RollsTest is BoxTestBase {
    function testFuzz_TenPackGuarantee(bytes32 randao) public {
        OGClubBox.Entry[] memory entries = defaultEntries();
        entries[2].cap = 0;
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        uint256 purchase = buy(10);
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        assertEq(expected[9], 3);
        assertOpenMatches(purchase, randao, header, false);
    }

    function test_CapsExhaustedWithinPackAndNeverRollAgain() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](2);
        entries[0] = OGClubBox.Entry(1, 0, 1, 0);
        entries[1] = OGClubBox.Entry(3, 4, 1e30, 1);
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        uint256 purchase = buy(10);
        bytes32 randao = keccak256("cap depletion");
        bytes memory header = ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        uint256 rares;
        for (uint256 i; i < expected.length; ++i) {
            if (expected[i] == 3) ++rares;
        }
        assertEq(rares, 1);
        assertEq(expected[9], 1); // The guarantee falls back when the only rare was consumed earlier.
        assertOpenMatches(purchase, randao, header, false);
        purchase = buy(10);
        header = ready(purchase, randao);
        expected = box.previewOpen(purchase, randao);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(expected[i], 1);
        }
        assertOpenMatches(purchase, randao, header, false);
        assertEq(box.minted(seasonId, 3), 1);
    }

    function testFuzz_RandomizedCapsNeverExceeded(bytes32 entropy, uint8 capA, uint8 capB) public {
        OGClubBox.Entry[] memory entries = defaultEntries();
        entries[1].cap = bound(capA, 1, 12);
        entries[2].cap = bound(capB, 1, 12);
        entries[1].weight = 100;
        entries[2].weight = 100;
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        for (uint256 round; round < 5; ++round) {
            uint256 purchase = buy(10);
            bytes32 randao = keccak256(abi.encode(entropy, round));
            bytes memory header = ready(purchase, randao);
            uint256[] memory expected = box.previewOpen(purchase, randao);
            for (uint256 j = 1; j < entries.length; ++j) {
                if (box.minted(seasonId, entries[j].itemId) == entries[j].cap) {
                    for (uint256 k; k < expected.length; ++k) {
                        assertNotEq(expected[k], entries[j].itemId);
                    }
                }
            }
            assertOpenMatches(purchase, randao, header, false);
        }
    }

    function test_SeedDomainMatchesSpecification() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](5);
        for (uint256 i; i < 5; ++i) {
            entries[i] = OGClubBox.Entry(i, uint8(i), 1, 0);
        }
        seasonId = box.createSeason(1, 1000, 100_000, 0, 0, entries);
        uint256 purchase = buy(9);
        bytes32 randao = keccak256("exact ABI encoding");
        ready(purchase, randao);
        uint256[] memory expected = box.previewOpen(purchase, randao);
        for (uint256 i; i < expected.length; ++i) {
            uint256 seed = uint256(keccak256(abi.encode(randao, block.chainid, address(box), purchase, i)));
            assertEq(expected[i], seed % 5);
        }
    }

    function test_GuaranteedRollUsesRelativeRareWeights() public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](4);
        entries[0] = OGClubBox.Entry(1, 0, 1_000_000, 0);
        entries[1] = OGClubBox.Entry(2, 2, 2, 0);
        entries[2] = OGClubBox.Entry(3, 3, 3, 0);
        entries[3] = OGClubBox.Entry(4, 4, 5, 0);
        seasonId = box.createSeason(1, 1000, 100_000, 0, 1, entries);
        uint256 purchase = buy(10);
        ready(purchase, bytes32(0));
        for (uint256 i; i < 100; ++i) {
            bytes32 randao = keccak256(abi.encode(i));
            uint256 roll =
                uint256(keccak256(abi.encode(randao, block.chainid, address(box), purchase, uint256(9)))) % 10;
            uint256 expected = roll < 2 ? 2 : roll < 5 ? 3 : 4;
            assertEq(box.previewOpen(purchase, randao)[9], expected);
        }
    }

    /// forge-config: default.fuzz.runs = 1
    function testFuzz_OddsOver20000Randao(bytes32 entropy) public {
        OGClubBox.Entry[] memory entries = new OGClubBox.Entry[](5);
        uint256[5] memory weights = [uint256(50), 25, 15, 7, 3];
        for (uint256 i; i < 5; ++i) {
            entries[i] = OGClubBox.Entry(i, uint8(i), weights[i], 0);
        }
        seasonId = box.createSeason(1, 1000, 100_000, 0, 0, entries);
        uint256 purchase = buy(1);
        ready(purchase, entropy);
        uint256[5] memory frequencies;
        // These are 20,000 independent view queries, not one on-chain transaction.
        // Do not impose a single transaction's gas budget on the statistical sample.
        vm.pauseGasMetering();
        for (uint256 i; i < 20_000; ++i) {
            bytes32 randao = keccak256(abi.encode(entropy, i));
            ++frequencies[box.previewOpen(purchase, randao)[0]];
        }
        vm.resumeGasMetering();
        uint256 samples;
        for (uint256 i; i < 5; ++i) {
            assertApproxEqAbs(frequencies[i], weights[i] * 200, 200, "frequency differs by over 1 percentage point");
            samples += frequencies[i];
        }
        assertEq(samples, 20_000);
    }
}
