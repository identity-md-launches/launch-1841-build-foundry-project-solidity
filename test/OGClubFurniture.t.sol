// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";

contract FurnitureTest is Test {
    OGClubFurniture internal furniture;
    address internal minter = makeAddr("minter");
    address internal buyer = makeAddr("buyer");
    address internal recipient = makeAddr("royalty recipient");

    function setUp() public {
        furniture = new OGClubFurniture(address(this), recipient);
    }

    function arrays() internal pure returns (uint256[] memory ids, uint256[] memory amounts) {
        ids = new uint256[](3);
        amounts = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 1;
        amounts[0] = 4;
        amounts[1] = 3;
        amounts[2] = 2;
    }

    function test_IdentityInterfacesMintAndSupply() public {
        assertEq(furniture.name(), "OG Club Furniture");
        assertEq(furniture.symbol(), "OGFURNI");
        assertTrue(furniture.supportsInterface(0xd9b67a26)); // ERC-1155
        assertTrue(furniture.supportsInterface(0x0e89341c)); // Metadata
        assertTrue(furniture.supportsInterface(0x2a55205a)); // ERC-2981
        assertTrue(furniture.supportsInterface(0x01ffc9a7)); // ERC-165
        assertFalse(furniture.supportsInterface(0xffffffff));
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, address(this)));
        furniture.mintBatch(buyer, ids, amounts);
        furniture.setMinter(minter, true);
        vm.prank(minter);
        furniture.mintBatch(buyer, ids, amounts);
        assertEq(furniture.balanceOf(buyer, 1), 6);
        assertEq(furniture.balanceOf(buyer, 2), 3);
        assertEq(furniture.totalSupply(1), 6);
        assertEq(furniture.totalSupply(), 9);
        assertTrue(furniture.exists(1));
        assertFalse(furniture.exists(42));
        furniture.setMinter(minter, false);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.NotMinter.selector, minter));
        furniture.mintBatch(buyer, ids, amounts);
    }

    function test_MetadataFreezesPermanently() public {
        assertEq(furniture.uri(0), "0.json");
        furniture.setBaseURI("ipfs://content/");
        assertEq(furniture.uri(123456), "ipfs://content/123456.json");
        furniture.freezeMetadata();
        assertTrue(furniture.metadataFrozen());
        vm.expectRevert(OGClubFurniture.MetadataFrozen.selector);
        furniture.setBaseURI("changed/");
        vm.expectRevert(OGClubFurniture.MetadataFrozen.selector);
        furniture.freezeMetadata();
    }

    function test_RoyaltyDefaultAndLimits() public {
        (address receiver, uint256 amount) = furniture.royaltyInfo(888, 10_000);
        assertEq(receiver, recipient);
        assertEq(amount, 500);
        furniture.setRoyalty(buyer, 1000);
        (receiver, amount) = furniture.royaltyInfo(1, 101);
        assertEq(receiver, buyer);
        assertEq(amount, 10);
        vm.expectRevert(abi.encodeWithSelector(OGClubFurniture.RoyaltyTooHigh.selector, uint96(1001)));
        furniture.setRoyalty(buyer, 1001);
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.setRoyalty(address(0), 0);
        furniture.setRoyalty(buyer, 0);
        (, amount) = furniture.royaltyInfo(1, 10_000);
        assertEq(amount, 0);
    }

    function test_NoOwnerSeizureOrBurn() public {
        (uint256[] memory ids, uint256[] memory amounts) = arrays();
        furniture.setMinter(minter, true);
        vm.prank(minter);
        furniture.mintBatch(buyer, ids, amounts);
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(this), buyer)
        );
        furniture.safeTransferFrom(buyer, address(this), 1, 1, "");
        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, address(this), buyer)
        );
        furniture.safeBatchTransferFrom(buyer, recipient, ids, amounts, "");
        (bool success,) = address(furniture).call(abi.encodeWithSignature("burn(address,uint256,uint256)", buyer, 1, 1));
        assertFalse(success);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(0)));
        furniture.safeTransferFrom(buyer, address(0), 1, 1, "");
        vm.prank(buyer);
        furniture.safeTransferFrom(buyer, recipient, 1, 2, "");
        assertEq(furniture.balanceOf(recipient, 1), 2);
        assertEq(furniture.totalSupply(1), 6);
    }

    function test_AllOwnerFunctionsProtected() public {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(furniture.setMinter, (minter, true));
        calls[1] = abi.encodeCall(furniture.setBaseURI, ("x/"));
        calls[2] = abi.encodeCall(furniture.freezeMetadata, ());
        calls[3] = abi.encodeCall(furniture.setRoyalty, (buyer, 100));
        calls[4] = abi.encodeCall(furniture.transferOwnership, (buyer));
        calls[5] = abi.encodeCall(furniture.renounceOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(buyer);
            (bool success, bytes memory reason) = address(furniture).call(calls[i]);
            assertFalse(success);
            assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        }
    }

    function test_OwnershipTwoStepAndRenounce() public {
        furniture.transferOwnership(buyer);
        assertEq(furniture.owner(), address(this));
        assertEq(furniture.pendingOwner(), buyer);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, minter));
        furniture.acceptOwnership();
        vm.prank(buyer);
        furniture.acceptOwnership();
        assertEq(furniture.owner(), buyer);
        assertEq(furniture.pendingOwner(), address(0));
        vm.prank(buyer);
        furniture.setBaseURI("new-owner/");
        vm.prank(buyer);
        furniture.renounceOwnership();
        assertEq(furniture.owner(), address(0));
    }

    function test_InvalidAddressesAndBatchLengths() public {
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        new OGClubFurniture(address(this), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OGClubFurniture(address(0), recipient);
        vm.expectRevert(OGClubFurniture.ZeroAddress.selector);
        furniture.setMinter(address(0), true);
        furniture.setMinter(address(this), true);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidArrayLength.selector, 1, 0));
        furniture.mintBatch(buyer, new uint256[](1), new uint256[](0));
    }
}
