// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {RoyaltyRegistry} from "manifoldxyz/RoyaltyRegistry.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

import {UsingLinearCurve} from "../../test/mixins/UsingLinearCurve.sol";
import {ConfigurableWithRoyalties} from "../mixins/ConfigurableWithRoyalties.sol";

import {AllowListHook} from "../../hooks/AllowListHook.sol";
import {SudoFactoryWrapper} from "../../bmx/SudoFactoryWrapper.sol";
import {SudoSingleFactoryWrapper} from "../../bmx/SudoSingleFactoryWrapper.sol";
import {SudoVRFRouter} from "../../bmx/SudoVRFRouter.sol";
import {LSSVMPairFactory} from "../../LSSVMPairFactory.sol";
import {ICurve} from "../../bonding-curves/ICurve.sol";
import {MockCurve} from "../../mocks/MockCurve.sol";
import {Test721} from "../../mocks/Test721.sol";
import {Test20} from "../../mocks/Test20.sol";
import {Test2981} from "../../mocks/Test2981.sol";
import {IERC721Mintable} from "../interfaces/IERC721Mintable.sol";
import {IERC1155Mintable} from "../interfaces/IERC1155Mintable.sol";
import {RoyaltyEngine} from "../../RoyaltyEngine.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {LSSVMPair} from "../../LSSVMPair.sol";
import {UsingERC20} from "../mixins/UsingERC20.sol";
import {MockVRFConsumer} from "../../mocks/MockVRFConsumer.sol";

contract BMXContractsTest is
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
    SudoSingleFactoryWrapper public singleFactoryWrapper;
    SudoVRFRouter public sudoVRFRouter;
    LSSVMPairFactory public pairFactory;
    ICurve public bondingCurve;
    IERC721 public testNFT;
    ERC20 public testToken;
    LSSVMPair public buyPair;
    LSSVMPair public sellPair;
    LSSVMPair public singleAssetPair;
    RoyaltyEngine royaltyEngine;
    MockVRFConsumer public vrfConsumer;

    function setUp() public {
        // Deploy ERC721 token and mint NFTs
        testNFT = setup721();
        IERC721Mintable(address(testNFT)).mint(address(this), 0);
        IERC721Mintable(address(testNFT)).mint(address(this), 1);
        IERC721Mintable(address(testNFT)).mint(address(this), 2); // For single asset pair
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

        // Deploy SudoFactoryWrapper and SudoSingleFactoryWrapper
        address[] memory whitelistedTokens = new address[](1);
        whitelistedTokens[0] = address(testToken);
        factoryWrapper = setupFactoryWrapper(pairFactory, whitelistedTokens);
        singleFactoryWrapper = setupSingleFactoryWrapper(
            pairFactory,
            address(bondingCurve),
            whitelistedTokens
        );

        // Deploy VRFConsumer
        vrfConsumer = new MockVRFConsumer();

        // Deploy SudoVRFRouter
        sudoVRFRouter = setupSudoVRFRouter(
            address(factoryWrapper),
            address(singleFactoryWrapper),
            address(vrfConsumer), // VRFConsumer address (mocked)
            address(1337) // Fee recipient
        );

        // Set collection fee for testNFT
        sudoVRFRouter.setCollectionFee(address(testNFT), 10000000000000000);

        // Set SudoVRFRouter in VRFConsumer
        vrfConsumer.setSudoVRFRouter(address(sudoVRFRouter));

        // Initialize AllowListHook with factory wrapper address and sudoVRFRouter address
        hook = setupAllowListHook(
            address(factoryWrapper),
            address(sudoVRFRouter)
        );

        // Set AllowListHook in factory wrapper and singleFactoryWrapper
        factoryWrapper.setAllowListHook(address(hook));
        singleFactoryWrapper.setAllowListHook(address(hook));

        // Set SudoVRFRouter in factory wrapper
        factoryWrapper.updateSudoVRFRouterConfig(address(sudoVRFRouter), 0, 0);

        // Create a buy and sell pool (PoolType.TOKEN and PoolType.NFT) with tokens owned by this contract
        uint128 delta = 0;
        uint128 spotPrice = 1 ether;
        uint256 lockDuration = 1 days;
        uint256 initialTokenBalance = 1 ether;

        testToken.approve(address(factoryWrapper), initialTokenBalance);
        testNFT.setApprovalForAll(address(factoryWrapper), true);
        testNFT.approve(address(singleFactoryWrapper), 2);

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
                initialTokenBalance
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
                0
            )
        );

        // Create a single asset pair via singleFactoryWrapper
        singleAssetPair = LSSVMPair(
            singleFactoryWrapper.createPair(
                address(testNFT),
                address(testToken),
                spotPrice,
                0,
                2
            )
        );
    }

    // Testing AllowListHook + SudoVRFRouter

    function test_sellNFTsUnauthorizedRecipientReverts() public {
        // Attempt to sell NFTs with recipient not being sudoVRFRouter
        address alice = address(6);
        IERC721Mintable(address(testNFT)).mint(alice, 5);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 5;
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

    function test_buySingleAssetNFTsUnauthorizedRecipientReverts() public {
        // Attempt to buy single NFT with recipient not being sudoVRFRouter
        address alice = address(1);
        IMintable(address(testToken)).mint(alice, 1 ether);
        vm.startPrank(alice);
        testToken.approve(address(singleAssetPair), 1 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.expectRevert(); // Should revert due to AllowListHook
        singleAssetPair.swapTokenForSpecificNFTs(
            ids,
            1 ether,
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
        // Verify that the correct amount of tokens was sent to the fee recipient
        assertEq(testToken.balanceOf(address(1337)), 14000000000000000);
    }

    function test_buySingleAssetNFTsAuthorizedRecipientSucceeds() public {
        // Alice buys single NFT through SudoVRFRouter
        address alice = address(1);
        IMintable(address(testToken)).mint(alice, 1.5 ether);
        vm.startPrank(alice);
        testToken.approve(address(sudoVRFRouter), 1.5 ether);
        sudoVRFRouter.buySingleNFT(address(singleAssetPair), 1.5 ether);
        vm.stopPrank();

        // Verify that Alice owns the NFT
        assertEq(testNFT.ownerOf(2), alice);
        // Verify that Alice paid the correct collection fee
        assertEq(testToken.balanceOf(address(1337)), 10000000000000000);
        // Verify that Alice is left with 0.49 ether
        assertEq(testToken.balanceOf(alice), 490000000000000000);
    }

    function test_buyNFTsAuthorizedRecipientSucceeds() public {
        // Alice buys NFTs through SudoVRFRouter
        address alice = address(1);
        IMintable(address(testToken)).mint(alice, 2 ether);
        vm.startPrank(alice);
        testToken.approve(address(sudoVRFRouter), 2 ether);
        uint256 requestId = sudoVRFRouter.buyRandomNFTs(
            address(sellPair),
            1,
            2 ether
        );
        vm.stopPrank();

        // Simulate next block
        vm.roll(block.number + 1);

        // Fulfill the random words request
        vm.prank(address(vrfConsumer)); // Simulate the VRFConsumer calling back
        vrfConsumer.fulfillRandomWords(requestId);

        // Verify that Alice owns either token ID 0 or token ID 1
        assertTrue(
            testNFT.ownerOf(0) == alice || testNFT.ownerOf(1) == alice,
            "Alice should own token ID 0 or 1"
        );
        // Verify that Alice paid the correct fee
        assertEq(testToken.balanceOf(address(1337)), 14000000000000000);
    }

    // Testing SudoFactoryWrapper

    function test_createERC721PairSucceeds() public {
        address alice = address(1);
        IERC721Mintable(address(testNFT)).mint(alice, 3);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3;
        vm.startPrank(alice);
        testNFT.setApprovalForAll(address(factoryWrapper), true);
        address pair = factoryWrapper.createPair(
            false,
            address(testNFT),
            address(testToken),
            address(bondingCurve),
            0,
            1 ether,
            1 days,
            new uint256[](0),
            0
        );
        vm.stopPrank();

        // Verify that the pair was created
        assertTrue(factoryWrapper.isPair(pair));
        // Verify that the pair is a sell pair
        assertTrue(LSSVMPair(pair).poolType() == LSSVMPair.PoolType.NFT);
        // Verify that alice is the owner of the pair
        assertTrue(factoryWrapper.getPairCreator(pair) == alice);
    }

    function test_createSingleAssetPairSucceeds() public {
        address alice = address(1);
        IERC721Mintable(address(testNFT)).mint(alice, 69);
        vm.startPrank(alice);
        testNFT.approve(address(singleFactoryWrapper), 69);
        // Create a single asset pair via singleFactoryWrapper
        address pair = singleFactoryWrapper.createPair(
            address(testNFT),
            address(testToken),
            1 ether,
            0,
            69
        );
        vm.stopPrank();

        // Verify that the pair was created
        assertTrue(singleFactoryWrapper.isPair(pair));
        // Verify that the pair is a sell pair
        assertTrue(LSSVMPair(pair).poolType() == LSSVMPair.PoolType.NFT);
        // Verify that alice is the owner of the pair
        assertTrue(singleFactoryWrapper.getPairCreator(pair) == alice);
        // Verify that the pair has no lock duration
        assertTrue(singleFactoryWrapper.getUnlockTime(pair) == 0);
    }

    function test_createERC1155PairReverts() public {
        IERC1155 test1155 = setup1155();
        address alice = address(1);
        IERC1155Mintable(address(test1155)).mint(alice, 1, 100);
        vm.startPrank(alice);
        test1155.setApprovalForAll(address(factoryWrapper), true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(); // Should revert because ERC1155 is not supported
        factoryWrapper.createPair(
            false,
            address(test1155),
            address(testToken),
            address(bondingCurve),
            0,
            1 ether,
            1 days,
            ids,
            0
        );
    }

    function test_rescueERC20TokensSucceeds() public {
        address alice = address(1);
        IMintable(address(testToken)).mint(alice, 1 ether);
        vm.startPrank(alice);
        testToken.transfer(address(sudoVRFRouter), 1 ether);
        vm.stopPrank();

        uint256[] memory amountOrIds = new uint256[](1);
        amountOrIds[0] = 1 ether;
        sudoVRFRouter.rescueTokens(true, address(testToken), amountOrIds);
        assertEq(testToken.balanceOf(address(this)), 100 ether); // we deploy a buy pair with 1 eth at start so left with 99, expect 100
    }

    function test_rescueERC721TokensSucceeds() public {
        address alice = address(1);
        IERC721Mintable(address(testNFT)).mint(alice, 1337);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1337;
        vm.startPrank(alice);
        testNFT.transferFrom(alice, address(sudoVRFRouter), 1337);
        vm.stopPrank();

        sudoVRFRouter.rescueTokens(false, address(testNFT), ids);
        assertEq(testNFT.ownerOf(1337), address(this));
    }

    function test_withdrawPairSucceeds() public {
        address alice = address(1);
        IERC721Mintable(address(testNFT)).mint(alice, 3);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3;

        vm.startPrank(alice);
        testNFT.setApprovalForAll(address(factoryWrapper), true);
        address pair = factoryWrapper.createPair(
            false,
            address(testNFT),
            address(testToken),
            address(bondingCurve),
            0,
            1 ether,
            1 days,
            new uint256[](0),
            0
        );

        vm.warp(block.timestamp + 1 days);

        factoryWrapper.withdrawPair(pair);
        vm.stopPrank();

        // Verify that the pair was withdrawn
        (, , bool hasWithdrawn) = factoryWrapper.pairInfo(pair);
        assertTrue(hasWithdrawn);
        assertTrue(LSSVMPair(pair).owner() == alice);
    }

    function test_withdrawSingleAssetPairSucceeds() public {
        address alice = address(1);
        IERC721Mintable(address(testNFT)).mint(alice, 69);
        vm.startPrank(alice);
        testNFT.approve(address(singleFactoryWrapper), 69);
        address pair = singleFactoryWrapper.createPair(
            address(testNFT),
            address(testToken),
            1 ether,
            0,
            69
        );

        singleFactoryWrapper.withdrawPair(pair);
        vm.stopPrank();

        // Verify that the pair was withdrawn
        (, , bool hasWithdrawn) = singleFactoryWrapper.pairInfo(pair);
        assertTrue(hasWithdrawn);
        assertTrue(LSSVMPair(pair).owner() == alice);
    }
}
