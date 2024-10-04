// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {RoyaltyRegistry} from "manifoldxyz/RoyaltyRegistry.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

import {UsingLinearCurve} from "../../test/mixins/UsingLinearCurve.sol";
import {ConfigurableWithRoyalties} from "../mixins/ConfigurableWithRoyalties.sol";

import {AllowListHook} from "../../hooks/AllowListHook.sol";
import {SudoFactoryWrapper} from "../../bmx/SudoFactoryWrapper.sol";
import {SudoVRFRouter} from "../../bmx/SudoVRFRouter.sol";
import {LSSVMPairFactory} from "../../LSSVMPairFactory.sol";
import {ICurve} from "../../bonding-curves/ICurve.sol";
import {MockCurve} from "../../mocks/MockCurve.sol";
import {Test721} from "../../mocks/Test721.sol";
import {Test20} from "../../mocks/Test20.sol";
import {Test2981} from "../../mocks/Test2981.sol";
import {IERC721Mintable} from "../interfaces/IERC721Mintable.sol";
import {RoyaltyEngine} from "../../RoyaltyEngine.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {LSSVMPair} from "../../LSSVMPair.sol";
import {UsingERC20} from "../mixins/UsingERC20.sol";

contract AllowListHookTest is
    Test,
    ConfigurableWithRoyalties,
    ERC721Holder,
    ERC1155Holder,
    UsingLinearCurve,
    UsingERC20
{
    using SafeTransferLib for ERC20;

    AllowListHook public hook;
    SudoFactoryWrapper public factoryWrapper;
    SudoVRFRouter public sudoVRFRouter;
    LSSVMPairFactory public pairFactory;
    ICurve public bondingCurve;
    IERC721 public testNFT;
    ERC20 public testToken;
    LSSVMPair public buyPair;
    LSSVMPair public sellPair;
    RoyaltyEngine royaltyEngine;

    function setUp() public {
        // Deploy ERC721 token and mint NFTs
        testNFT = setup721();
        IERC721Mintable(address(testNFT)).mint(address(this), 0);
        IERC721Mintable(address(testNFT)).mint(address(this), 1);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;

        // Deploy ERC20 token and mint tokens
        testToken = new Test20();
        IMintable(address(testToken)).mint(address(this), 100 ether);

        // Deploy bonding curve
        bondingCurve = setupCurve();

        // Set up royalties for the test 721
        royaltyEngine = setupRoyaltyEngine();
        ERC2981 royaltyLookup = ERC2981(
            new Test2981(payable(address(this)), 0)
        );
        RoyaltyRegistry(royaltyEngine.ROYALTY_REGISTRY())
            .setRoyaltyLookupAddress(address(testNFT), address(royaltyLookup));

        // LSSVMPairFactory without protocol fee
        pairFactory = setupFactory(royaltyEngine, payable(address(0)));
        pairFactory.setBondingCurveAllowed(bondingCurve, true);

        // Deploy SudoFactoryWrapper
        address[] memory whitelistedTokens = new address[](1);
        whitelistedTokens[0] = address(testToken);
        factoryWrapper = setupFactoryWrapper(pairFactory, whitelistedTokens);

        // Deploy SudoVRFRouter
        sudoVRFRouter = setupSudoVRFRouter(
            address(factoryWrapper),
            address(5), // VRFConsumer address (mocked)
            address(this) // Fee recipient
        );

        // Initialize AllowListHook with factory wrapper address and sudoVRFRouter address
        hook = setupAllowListHook(
            address(factoryWrapper),
            address(sudoVRFRouter)
        );

        // Set AllowListHook in factory wrapper
        factoryWrapper.setAllowListHook(address(hook));
        // Set SudoVRFRouter in factory wrapper
        factoryWrapper.updateSudoVRFRouterConfig(
            address(sudoVRFRouter),
            0,
            0,
            0,
            0
        );

        // Create a buy and sell pool (PoolType.TOKEN and PoolType.NFT) with tokens owned by this contract
        uint128 delta = 0;
        uint128 spotPrice = 1 ether;
        uint256 lockDuration = 1 days;
        uint256 initialTokenBalance = 1 ether;

        testToken.approve(address(factoryWrapper), initialTokenBalance);
        testNFT.setApprovalForAll(address(factoryWrapper), true);

        // Create buy pair via factory wrapper
        buyPair = LSSVMPair(
            factoryWrapper.createPair(
                true,
                address(testNFT),
                address(testToken),
                address(bondingCurve),
                delta,
                spotPrice,
                lockDuration,
                new uint256[](0),
                initialTokenBalance,
                0
            )
        );

        // Create sell pair via factory wrapper
        sellPair = LSSVMPair(
            factoryWrapper.createPair(
                false,
                address(testNFT),
                address(testToken),
                address(bondingCurve),
                delta,
                spotPrice,
                lockDuration,
                ids,
                0,
                0
            )
        );
    }

    function test_sellNFTsUnauthorizedRecipientReverts() public {
        // Attempt to sell NFTs with recipient not being sudoVRFRouter
        address alice = address(6);
        IERC721Mintable(address(testNFT)).mint(alice, 2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.startPrank(alice);
        testNFT.setApprovalForAll(address(buyPair), true);
        vm.expectRevert(); // Should revert due to AllowListHook
        buyPair.swapNFTsForToken(
            ids,
            0.95 ether,
            payable(alice),
            false,
            address(0)
        );
        vm.stopPrank();
    }

    function test_buyNFTsUnauthorizedRecipientReverts() public {
        // Attempt to buy NFTs with recipient not being sudoVRFRouter
        address alice = address(1);
        IMintable(address(testToken)).mint(alice, 1 ether);
        vm.startPrank(alice);
        testToken.approve(address(sellPair), 1 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(); // Should revert due to AllowListHook
        sellPair.swapTokenForSpecificNFTs(
            ids,
            1 ether,
            payable(alice),
            false,
            address(0)
        );
        vm.stopPrank();
    }

    function test_sellNFTsAuthorizedRecipientSucceeds() public {
        // Alice sells NFTs through SudoVRFRouter
        address alice = address(1);
        IERC721Mintable(address(testNFT)).mint(alice, 3);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3;
        vm.startPrank(alice);
        testNFT.setApprovalForAll(address(sudoVRFRouter), true);
        sudoVRFRouter.sellNFTs(address(buyPair), ids, 0.9 ether);
        vm.stopPrank();

        // Verify that we own the NFT
        assertEq(testNFT.ownerOf(3), address(this));
    }
}
