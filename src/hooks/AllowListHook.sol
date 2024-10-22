// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Owned} from "solmate/auth/Owned.sol";

import {IPairHooks} from "./IPairHooks.sol";
import {LSSVMPair} from "../LSSVMPair.sol";
import {ISudoVRFRouter} from "../bmx/Interfaces.sol";

/**
 * @title AllowListHook
 * @notice This contract is used to manage allow lists for NFTs.
 * @dev Modified to allow for a single router address to be set for all NFTs in the allow list.
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

    // =========================================
    // Errors
    // =========================================

    error AllowListHook__WrongOwner();
    error AllowListHook__NotAllowedSender();
    error AllowListHook__UnsupportedNFTInterface();

    // =========================================
    // Events
    // =========================================

    event AllowListUpdatedWithNewRouter(address newRouter);

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

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Updates the allow list with a new router address.
     * @dev Only the factory wrapper can call this function when upgrading to a new router.
     * @param _newRouter The new router address to set for all NFT IDs in the allow list.
     */
    function updateAllowListWithNewRouter(
        address _newRouter
    ) external onlyFactoryWrapper {
        sudoVRFRouter = _newRouter;

        emit AllowListUpdatedWithNewRouter(_newRouter);
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
        if (!ISudoVRFRouter(sudoVRFRouter).allowedSenders(msg.sender)) {
            revert AllowListHook__NotAllowedSender();
        }

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

        // Check the NFT interface
        if (IERC165(nftAddress).supportsInterface(type(IERC721).interfaceId)) {
            for (uint256 i = 0; i < _nfts.length; ) {
                uint256 id = _nfts[i];
                if (IERC721(nftAddress).ownerOf(id) != sudoVRFRouter) {
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
