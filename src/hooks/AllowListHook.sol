// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import {IPairHooks} from "./IPairHooks.sol";
import {LSSVMPair} from "../LSSVMPair.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Owned} from "solmate/auth/Owned.sol";

contract AllowListHook is IPairHooks, Owned {
    mapping(uint256 => address) public allowList;
    error AllowListHook__WrongOwner();
    error AllowListHook__UnsupportedNFTInterface();

    constructor() Owned(msg.sender) {}

    // Owner function to modify the allow list
    function modifyAllowList(
        uint256[] calldata ids,
        address[] calldata allowedBuyers
    ) external onlyOwner {
        for (uint i; i < ids.length; ) {
            allowList[ids[i]] = allowedBuyers[i];

            unchecked {
                ++i;
            }
        }
    }

    function modifyAllowListSingleBuyer(
        uint256[] calldata ids,
        address allowedBuyer
    ) external onlyOwner {
        for (uint i; i < ids.length; ) {
            allowList[ids[i]] = allowedBuyer;

            unchecked {
                ++i;
            }
        }
    }

    function afterSwapNFTOutPair(
        uint256,
        uint256,
        uint256,
        uint256[] calldata _nftsOut
    ) external {
        _checkAllowList(_nftsOut);
    }

    function afterSwapNFTInPair(
        uint256,
        uint256,
        uint256,
        uint256[] calldata _nftsIn
    ) external {
        _checkAllowList(_nftsIn);
    }

    function _checkAllowList(uint256[] calldata _nfts) internal {
        address nftAddress = LSSVMPair(msg.sender).nft();

        // Detect the NFT interface
        bool isERC721 = IERC165(nftAddress).supportsInterface(
            type(IERC721).interfaceId
        );
        bool isERC1155 = IERC165(nftAddress).supportsInterface(
            type(IERC1155).interfaceId
        );

        if (isERC721) {
            IERC721 nft = IERC721(nftAddress);
            for (uint256 i; i < _nfts.length; ) {
                uint256 id = _nfts[i];
                address desiredOwner = allowList[id];
                if (nft.ownerOf(id) != desiredOwner) {
                    revert AllowListHook__WrongOwner();
                }

                unchecked {
                    ++i;
                }
            }
        } else if (isERC1155) {
            IERC1155 nft = IERC1155(nftAddress);
            for (uint256 i; i < _nfts.length; ) {
                uint256 id = _nfts[i];
                address desiredOwner = allowList[id];
                uint256 balance = nft.balanceOf(desiredOwner, id);
                if (balance == 0) {
                    revert AllowListHook__WrongOwner();
                }

                unchecked {
                    ++i;
                }
            }
        } else {
            revert AllowListHook__UnsupportedNFTInterface();
        }
    }

    // Stub implementations after here
    function afterNewPair() external {}

    function afterDeltaUpdate(uint128 _oldDelta, uint128 _newDelta) external {}

    function afterSpotPriceUpdate(
        uint128 _oldSpotPrice,
        uint128 _newSpotPrice
    ) external {}

    function afterFeeUpdate(uint96 _oldFee, uint96 _newFee) external {}

    function afterNFTWithdrawal(uint256[] calldata _nftsOut) external {}

    function afterTokenWithdrawal(uint256 _tokensOut) external {}

    function syncForPair(
        address pairAddress,
        uint256 _tokensIn,
        uint256[] calldata _nftsIn
    ) external {}
}
