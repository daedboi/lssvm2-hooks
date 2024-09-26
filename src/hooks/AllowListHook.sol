// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import {IPairHooks} from "./IPairHooks.sol";
import {LSSVMPair} from "../LSSVMPair.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Owned} from "solmate/auth/Owned.sol";

/**
 * @title AllowListHook
 * @notice This contract is used to manage allow lists for NFTs.
 */
contract AllowListHook is IPairHooks, Owned {
    // =========================================
    // Immutable Variables
    // =========================================

    /// @notice The address of the SudoFactoryWrapper contract.
    address public immutable factoryWrapper;

    // =========================================
    // State Variables
    // =========================================

    /// @notice Mapping from NFT ID to the allowed buyer's address.
    mapping(uint256 => address) public allowList;

    // =========================================
    // Errors
    // =========================================

    /// @notice Error thrown when the NFT is not owned by the desired owner.
    error AllowListHook__WrongOwner();

    /// @notice Error thrown when the NFT interface is unsupported.
    error AllowListHook__UnsupportedNFTInterface();

    // =========================================
    // Events
    // =========================================

    /// @notice Emitted when the allow list is modified.
    event AllowListModified(uint256[] ids, address[] allowedBuyers);

    /// @notice Emitted when the allow list is modified for a single buyer.
    event AllowListModifiedSingleBuyer(uint256[] ids, address allowedBuyer);

    // =========================================
    // Constructor
    // =========================================

    constructor(address _factoryWrapper) Owned(msg.sender) {
        require(_factoryWrapper != address(0), "Invalid factory wrapper");

        factoryWrapper = _factoryWrapper;
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlyFactoryWrapper() {
        require(
            msg.sender == factoryWrapper,
            "Only the factory wrapper can call this function"
        );
        _;
    }

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Modifies the allow list with specified NFT IDs and corresponding allowed buyers.
     * @dev Only the owner can call this function for manual fixes if needed.
     * @param ids The array of NFT IDs.
     * @param allowedBuyers The array of addresses allowed to receive the corresponding NFTs.
     */
    function modifyAllowList(
        uint256[] calldata ids,
        address[] calldata allowedBuyers
    ) external onlyOwner {
        require(
            ids.length == allowedBuyers.length,
            "Arrays must be of equal length"
        );
        for (uint i = 0; i < ids.length; ) {
            allowList[ids[i]] = allowedBuyers[i];

            unchecked {
                ++i;
            }
        }

        emit AllowListModified(ids, allowedBuyers);
    }

    /**
     * @notice Modifies the allow list for multiple NFT IDs with a single allowed buyer.
     * @dev Only the factory wrapper can call this function.
     * @param ids The array of NFT IDs.
     * @param allowedBuyer The address allowed to receive the specified NFTs.
     */
    function modifyAllowListSingleBuyer(
        uint256[] calldata ids,
        address allowedBuyer
    ) external onlyFactoryWrapper {
        for (uint i = 0; i < ids.length; ) {
            allowList[ids[i]] = allowedBuyer;

            unchecked {
                ++i;
            }
        }

        emit AllowListModifiedSingleBuyer(ids, allowedBuyer);
    }

    /**
     * @notice Hook function called after NFTs are swapped out of the pair.
     * @param _nftsOut The array of NFT IDs swapped out of the pair.
     */
    function afterSwapNFTOutPair(
        uint256,
        uint256,
        uint256,
        uint256[] calldata _nftsOut
    ) external {
        _checkAllowList(_nftsOut);
    }

    /**
     * @notice Hook function called after NFTs are swapped into the pair.
     * @param _nftsIn The array of NFT IDs swapped into the pair.
     */
    function afterSwapNFTInPair(
        uint256,
        uint256,
        uint256,
        uint256[] calldata _nftsIn
    ) external {
        _checkAllowList(_nftsIn);
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

    // =========================================
    // Internal Functions
    // =========================================

    /**
     * @notice Checks whether the NFTs are owned by the allowed buyers as per the allow list.
     * @param _nfts The array of NFT IDs to check.
     */
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
            for (uint256 i = 0; i < _nfts.length; ) {
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
            for (uint256 i = 0; i < _nfts.length; ) {
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
}
