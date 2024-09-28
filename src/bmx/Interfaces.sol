// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract CurveErrorCodes {
    enum Error {
        OK, // No error
        INVALID_NUMITEMS, // The numItem value is 0
        SPOT_PRICE_OVERFLOW, // The updated spot price doesn't fit into 128 bits
        DELTA_OVERFLOW, // The updated delta doesn't fit into 128 bits
        SPOT_PRICE_UNDERFLOW // The updated spot price goes too low
    }
}

interface ILSSVMPair {
    enum PoolType {
        TOKEN,
        NFT,
        TRADE
    }

    function nft() external view returns (address);

    function poolType() external view returns (PoolType);

    function pairVariant()
        external
        pure
        returns (ILSSVMPairFactory.PairVariant);

    function withdrawERC721(IERC721 nft, uint256[] calldata nftIds) external;

    function withdrawETH(uint256 amount) external;

    function withdrawERC20(ERC20 token, uint256 amount) external;

    function withdrawERC1155(
        IERC1155 nft,
        uint256[] calldata ids,
        uint256[] calldata amounts
    ) external;

    function token() external view returns (ERC20);

    function nftId() external view returns (uint256);

    function getAllIds() external view returns (uint256[] memory);

    function swapTokenForSpecificNFTs(
        uint256[] calldata nftIds,
        uint256 maxExpectedTokenInput,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    ) external payable returns (uint256 amountUsed);

    function swapNFTsForToken(
        uint256[] calldata nftIds,
        uint256 minExpectedTokenOutput,
        address payable tokenRecipient,
        bool isRouter,
        address routerCaller
    ) external returns (uint256 outputAmount);

    function getBuyNFTQuote(
        uint256 assetId,
        uint256 numNFTs
    )
        external
        view
        returns (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 newDelta,
            uint256 inputAmount,
            uint256 protocolFee,
            uint256 royaltyAmount
        );

    function getSellNFTQuote(
        uint256 assetId,
        uint256 numNFTs
    )
        external
        view
        returns (
            CurveErrorCodes.Error error,
            uint256 newSpotPrice,
            uint256 newDelta,
            uint256 inputAmount,
            uint256 protocolFee,
            uint256 royaltyAmount
        );
}

interface ILSSVMPairFactory {
    enum PairVariant {
        ERC721_ETH,
        ERC721_ERC20,
        ERC1155_ETH,
        ERC1155_ERC20
    }

    struct CreateERC721ERC20PairParams {
        ERC20 token;
        IERC721 nft;
        ICurve bondingCurve;
        address payable assetRecipient;
        ILSSVMPair.PoolType poolType;
        uint128 delta;
        uint96 fee;
        uint128 spotPrice;
        address propertyChecker;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
        address hookAddress;
        address referralAddress;
    }

    struct CreateERC1155ERC20PairParams {
        ERC20 token;
        IERC1155 nft;
        ICurve bondingCurve;
        address payable assetRecipient;
        ILSSVMPair.PoolType poolType;
        uint128 delta;
        uint96 fee;
        uint128 spotPrice;
        uint256 nftId;
        uint256 initialNFTBalance;
        uint256 initialTokenBalance;
        address hookAddress;
        address referralAddress;
    }

    function createPairERC721ETH(
        IERC721 nft,
        ICurve bondingCurve,
        address payable assetRecipient,
        ILSSVMPair.PoolType poolType,
        uint128 delta,
        uint96 fee,
        uint128 spotPrice,
        address propertyChecker,
        uint256[] calldata initialNFTIDs,
        address hookAddress,
        address referralAddress
    ) external payable returns (ILSSVMPair pair);

    function createPairERC721ERC20(
        ILSSVMPairFactory.CreateERC721ERC20PairParams calldata params
    ) external returns (ILSSVMPair pair);

    function createPairERC1155ETH(
        IERC1155 nft,
        ICurve bondingCurve,
        address payable assetRecipient,
        ILSSVMPair.PoolType poolType,
        uint128 delta,
        uint96 fee,
        uint128 spotPrice,
        uint256 nftId,
        uint256 initialNFTBalance,
        address hookAddress,
        address referralAddress
    ) external payable returns (ILSSVMPair pair);

    function createPairERC1155ERC20(
        ILSSVMPairFactory.CreateERC1155ERC20PairParams calldata params
    ) external returns (ILSSVMPair pair);
}

interface ICurve {
    // Only used as a parameter for pair creation
}

interface IAllowListHook {
    function modifyAllowListSingleBuyer(
        uint256[] calldata nftIds,
        address buyer
    ) external;
}

interface IVRFConsumer {
    function requestRandomWords(
        uint32 numWords
    ) external returns (uint256 requestId);
}

interface ISudoVRFWrapper {
    function buyNFTsCallback(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external;
}

interface ISudoFactoryWrapper {
    function isPair(address pair) external view returns (bool);

    function isRandomPair(address pair) external view returns (bool);
}
