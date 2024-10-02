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

    /// @notice The address of the SudoVRFRouter contract.
    address public sudoVRFRouter;

    /// @notice Mapping from NFT ID to allowed buyer.
    mapping(uint256 => address) public allowList;

    /// @notice The length of the allow list.
    uint256 public allowListLength;

    // =========================================
    // Errors
    // =========================================

    error AllowListHook__WrongOwner();
    error AllowListHook__UnsupportedNFTInterface();

    // =========================================
    // Events
    // =========================================

    event AllowListModified(uint256[] ids, address[] allowedBuyers);
    event AllowListModifiedSingleBuyer(uint256[] ids, address allowedBuyer);
    event AllowListUpdatedWithNewRouter(
        address newRouter,
        uint256 offset,
        uint256 limit
    );

    // =========================================
    // Constructor
    // =========================================

    constructor(
        address _factoryWrapper,
        address _sudoVRFRouter
    ) Owned(msg.sender) {
        require(_factoryWrapper != address(0), "Invalid factory wrapper");
        require(_sudoVRFRouter != address(0), "Invalid sudoVRFRouter");

        factoryWrapper = _factoryWrapper;
        sudoVRFRouter = _sudoVRFRouter;
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

    modifier onlyFactoryOrRouter() {
        require(
            msg.sender == factoryWrapper || msg.sender == sudoVRFRouter,
            "Only the factory wrapper or sudoVRFRouter can call this function"
        );
        _;
    }

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Modifies the allow list with specified NFT IDs and corresponding allowed buyers.
     * @dev Only the owner can call this function for manual fixes if needed.
     * @param _ids The array of NFT IDs.
     * @param _allowedBuyers The array of addresses allowed to receive the corresponding NFTs.
     */
    function modifyAllowList(
        uint256[] calldata _ids,
        address[] calldata _allowedBuyers
    ) external onlyOwner {
        require(
            _ids.length == _allowedBuyers.length,
            "Arrays must be of equal length"
        );
        for (uint i = 0; i < _ids.length; ) {
            require(_allowedBuyers[i] != address(0), "Invalid allowed buyer");

            if (allowList[_ids[i]] == address(0)) {
                allowListLength++;
            }

            allowList[_ids[i]] = _allowedBuyers[i];

            unchecked {
                ++i;
            }
        }

        emit AllowListModified(_ids, _allowedBuyers);
    }

    /**
     * @notice Modifies the allow list for multiple NFT IDs with a single allowed buyer.
     * @dev Only the factory wrapper can call this function.
     * @param _ids The array of NFT IDs.
     * @param _allowedBuyer The address allowed to receive the specified NFTs.
     */
    function modifyAllowListSingleBuyer(
        uint256[] calldata _ids,
        address _allowedBuyer
    ) external onlyFactoryOrRouter {
        require(_allowedBuyer != address(0), "Invalid allowed buyer");
        for (uint i = 0; i < _ids.length; ) {
            if (allowList[_ids[i]] == address(0)) {
                allowListLength++;
            }

            allowList[_ids[i]] = _allowedBuyer;

            unchecked {
                ++i;
            }
        }

        emit AllowListModifiedSingleBuyer(_ids, _allowedBuyer);
    }

    /**
     * @notice Updates the allow list with a new router address.
     * @dev Only the factory wrapper can call this function when upgrading to a new router.
     * @param _newRouter The new router address to set for all NFT IDs in the allow list.
     * @param _offset The offset of the allow list to update.
     * @param _limit The limit of the allow list to update.
     */
    function updateAllowListWithNewRouter(
        address _newRouter,
        uint256 _offset,
        uint256 _limit
    ) external onlyFactoryWrapper {
        require(_newRouter != address(0), "Invalid new router");
        require(
            _offset < allowListLength && _limit > 0,
            "Invalid offset or limit"
        );

        uint256 end = _offset + _limit > allowListLength
            ? allowListLength
            : _offset + _limit;

        uint256 count = 0;
        for (uint256 i = 0; count < end; ) {
            if (allowList[i] != address(0)) {
                if (count >= _offset) {
                    allowList[i] = _newRouter;
                }
                count++;
            }

            unchecked {
                ++i;
            }
        }

        sudoVRFRouter = _newRouter;

        emit AllowListUpdatedWithNewRouter(_newRouter, _offset, _limit);
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
            for (uint256 i = 0; i < _nfts.length; ) {
                uint256 id = _nfts[i];
                address desiredOwner = allowList[id];
                if (IERC721(nftAddress).ownerOf(id) != desiredOwner) {
                    revert AllowListHook__WrongOwner();
                }

                unchecked {
                    ++i;
                }
            }
        } else if (isERC1155) {
            for (uint256 i = 0; i < _nfts.length; ) {
                uint256 id = _nfts[i];
                address desiredOwner = allowList[id];
                uint256 balance = IERC1155(nftAddress).balanceOf(
                    desiredOwner,
                    id
                );
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
