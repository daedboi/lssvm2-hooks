// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {ILSSVMPairFactory, ILSSVMPair, ICurve, IAllowListHook} from "./Interfaces.sol";

/**
 * @title SudoFactoryWrapper
 * @author 0xdaedboi
 * @notice A wrapper contract for managing SudoSwap v2 pair creation and withdrawals with additional features.
 * @dev This contract provides a higher-level interface for creating and managing SudoSwap pairs, with added lock mechanisms and access control.
 */
contract SudoFactoryWrapper is
    Ownable,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder
{
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;

    // =========================================
    // Constants and Immutable Variables
    // =========================================

    /// @notice Minimum lock duration for a pair (12 hours)
    uint256 public constant MIN_LOCK_DURATION = 12 hours;

    /// @notice Factory instance to create pairs
    ILSSVMPairFactory public immutable factory;

    // =========================================
    // State Variables
    // =========================================

    /// @notice Instance of the AllowListHook for managing allowed addresses
    IAllowListHook public allowListHook;

    /// @notice Address of the SudoVRFRouter contract.
    /// @dev Needs to be whitelisted in AllowListHook and set as asset recipient for buy pairs.
    address public sudoVRFRouter;

    /// @notice Minimum duration that a pair must remain locked
    uint256 public minimumLockDuration;

    /// @notice Array of all buy pairs created by this factory wrapper.
    /// @dev Used to update all asset recipients for buy pairs when sudoVRFRouter is updated.
    address[] public buyPairs;

    /// @notice Mapping to store pair information
    mapping(address => PairInfo) public pairInfo;

    /// @notice Mapping to store pair addresses created by a user
    mapping(address => address[]) public pairsByCreator;

    /// @notice Mapping to store if an address is a pair
    mapping(address => bool) public isPair;

    /// @notice Mapping to store if a pair is a random pair (VRF ERC721 buy pool)
    mapping(address => bool) public isRandomPair;

    // =========================================
    // Structs
    // =========================================

    /// @notice Struct to store pair information
    struct PairInfo {
        address pairAddress; // Pair address
        uint256 pairUnlockTime; // Timestamp when the pair will be unlocked
        address pairCreator; // Address of the pair creator
        bool hasWithdrawn; // Whether the pair has been withdrawn from
    }

    /// @notice Struct to store create pair parameters
    struct CreatePairParams {
        address sender;
        bool isBuy;
        bool isRandom;
        bool isETH;
        address nft;
        address token;
        address bondingCurve;
        uint128 delta;
        uint128 spotPrice;
        uint256 lockDuration;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
        uint256 initialNFTBalance;
    }

    // =========================================
    // Events
    // =========================================

    event PairCreated(
        address indexed pair,
        address indexed creator,
        uint256 unlockTime,
        bool isERC721,
        bool isETH,
        bool isBuy,
        bool isRandom
    );
    event PairWithdrawal(
        address indexed pair,
        address indexed withdrawer,
        uint256[] nftIds,
        uint256 amountTokenOrETH,
        uint256 amountERC1155
    );
    event AllowListHookUpdated(address newAllowListHook);
    event SudoVRFRouterConfigUpdated(
        address newSudoVRFRouter,
        uint256 pairOffset,
        uint256 pairLimit,
        uint256 allowListOffset,
        uint256 allowListLimit
    );
    event MinimumLockDurationUpdated(uint256 newMinimumLockDuration);

    // =========================================
    // Constructor
    // =========================================

    /**
     * @notice Initializes the contract with factory and allow list hook.
     * @param _factory Address of the LSSVMPairFactory.
     * @param _minimumLockDuration Minimum lock duration for a pair.
     */
    constructor(address _factory, uint256 _minimumLockDuration) {
        require(_factory != address(0), "Invalid factory address");
        require(
            _minimumLockDuration >= MIN_LOCK_DURATION,
            "Invalid lock duration"
        );
        factory = ILSSVMPairFactory(payable(_factory));
        minimumLockDuration = _minimumLockDuration;
    }

    /**
     * @notice Allows the contract to receive ETH.
     */
    receive() external payable {}

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Creates a new pair with specified parameters.
     * @dev Depending on the NFT type (ERC721 or ERC1155) and whether the pair is ETH or ERC20-based, it calls the appropriate internal function.
     * @param _isBuy Determines if the pair is a buy or sell pair.
     * @param _isRandom Determines if the pair is a random pair using Chainlink VRF (only for ERC721 buy pools).
     * @param _nft Address of the NFT contract.
     * @param _token Address of the ERC20 token (use address(0) for ETH).
     * @param _bondingCurve Address of the bonding curve contract.
     * @param _delta Delta parameter for the bonding curve.
     * @param _spotPrice Initial spot price for the pair.
     * @param _lockDuration Duration for which the pair is locked.
     * @param _initialNFTIDs Array of initial NFT IDs to be added for ERC7721 or single ID for ERC1155.
     * @param _initialTokenBalance Initial token balance to be added (ERC20).
     * @param _initialNFTBalance Initial NFT balance for ERC1155 pairs.
     * @return pairAddress Address of the created pair.
     */
    function createPair(
        bool _isBuy,
        bool _isRandom,
        address _nft,
        address _token,
        address _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs,
        uint256 _initialTokenBalance,
        uint256 _initialNFTBalance
    ) external payable nonReentrant returns (address pairAddress) {
        require(
            _nft != address(0) && address(_bondingCurve) != address(0),
            "Invalid NFT or bonding curve address"
        );
        require(
            _lockDuration >= minimumLockDuration,
            "Lock duration must be at least 24 hours"
        );
        require(
            _supportsInterface(_nft, type(IERC721).interfaceId) ||
                _supportsInterface(_nft, type(IERC1155).interfaceId),
            "Invalid NFT"
        );

        // Check if NFT is ERC721
        if (_supportsInterface(_nft, type(IERC721).interfaceId)) {
            // Check if token is ETH
            if (_token == address(0)) {
                pairAddress = _createERC721ETHPair(
                    CreatePairParams(
                        msg.sender,
                        _isBuy,
                        _isRandom,
                        _token == address(0), // isETH
                        _nft,
                        _token,
                        _bondingCurve,
                        _delta,
                        _spotPrice,
                        _lockDuration,
                        _initialNFTIDs,
                        _initialTokenBalance,
                        _initialNFTBalance
                    )
                );
            }
            // Token is ERC20
            else {
                pairAddress = _createERC721ERC20Pair(
                    CreatePairParams(
                        msg.sender,
                        _isBuy,
                        _isRandom,
                        _token == address(0), // isETH
                        _nft,
                        _token,
                        _bondingCurve,
                        _delta,
                        _spotPrice,
                        _lockDuration,
                        _initialNFTIDs,
                        _initialTokenBalance,
                        _initialNFTBalance
                    )
                );
            }
        }
        // Check if NFT is ERC1155
        else if (_supportsInterface(_nft, type(IERC1155).interfaceId)) {
            // Check if token is ETH
            if (_token == address(0)) {
                pairAddress = _createERC1155ETHPair(
                    CreatePairParams(
                        msg.sender,
                        _isBuy,
                        _isRandom,
                        _token == address(0), // isETH
                        _nft,
                        _token,
                        _bondingCurve,
                        _delta,
                        _spotPrice,
                        _lockDuration,
                        _initialNFTIDs,
                        _initialTokenBalance,
                        _initialNFTBalance
                    )
                );
            }
            // Token is ERC20
            else {
                pairAddress = _createERC1155ERC20Pair(
                    CreatePairParams(
                        msg.sender,
                        _isBuy,
                        _isRandom,
                        _token == address(0), // isETH
                        _nft,
                        _token,
                        _bondingCurve,
                        _delta,
                        _spotPrice,
                        _lockDuration,
                        _initialNFTIDs,
                        _initialTokenBalance,
                        _initialNFTBalance
                    )
                );
            }
        }
        // Invalid NFT
        else {
            revert("Invalid NFT");
        }

        return pairAddress;
    }

    /**
     * @notice Withdraws all assets from a specified pair after lock duration.
     * @param _pair Address of the pair to withdraw from.
     * @return nftIds Array of NFT IDs withdrawn. For ERC1155, only one ID is returned.
     * @return amountTokenOrETH Amount of ERC20 or ETH withdrawn.
     * @return amountERC1155 Amount of ERC1155 NFTs withdrawn (0 for ERC721).
     */
    function withdraw(
        address _pair
    )
        external
        nonReentrant
        returns (
            uint256[] memory nftIds,
            uint256 amountTokenOrETH,
            uint256 amountERC1155
        )
    {
        require(_pair != address(0) && isPair[_pair], "Invalid pair address");

        address sender = msg.sender;
        PairInfo memory info = pairInfo[_pair];
        ILSSVMPair pair = ILSSVMPair(_pair);
        address nft = pair.nft();

        require(sender == info.pairCreator, "Only the creator can withdraw");
        require(info.hasWithdrawn == false, "Pair already withdrawn");
        require(block.timestamp >= info.pairUnlockTime, "Pair is still locked");

        pairInfo[_pair].hasWithdrawn = true;
        (nftIds, amountTokenOrETH, amountERC1155) = _withdrawAssets(
            pair,
            nft,
            sender
        );

        emit PairWithdrawal(
            _pair,
            sender,
            nftIds,
            amountTokenOrETH,
            amountERC1155
        );

        return (nftIds, amountTokenOrETH, amountERC1155);
    }

    // =========================================
    // View Functions
    // =========================================

    /**
     * @notice Retrieves the unlock time for a specified pair.
     * @param _pair Address of the pair.
     * @return The unlock time for the pair.
     */
    function getUnlockTime(address _pair) external view returns (uint256) {
        return pairInfo[_pair].pairUnlockTime;
    }

    /**
     * @notice Retrieves the creator of a specified pair.
     * @param _pair Address of the pair.
     * @return The creator of the pair.
     */
    function getPairCreator(address _pair) external view returns (address) {
        return pairInfo[_pair].pairCreator;
    }

    /**
     * @notice Retrieves all pairs created by a specific creator.
     * @param _creator Address of the creator.
     * @param _offset The offset of the pairs to retrieve.
     * @param _limit The maximum number of pairs to retrieve.
     * @return pairsInfo An array of PairInfo structs containing pair details.
     * @return hasMore Whether there are more pairs to retrieve.
     */
    function getAllPairsInfoByCreator(
        address _creator,
        uint256 _offset,
        uint256 _limit
    ) external view returns (PairInfo[] memory, bool hasMore) {
        address[] memory pairs = pairsByCreator[_creator];
        uint256 end = _offset + _limit > pairs.length
            ? pairs.length
            : _offset + _limit;
        PairInfo[] memory pairsInfo = new PairInfo[](end - _offset);
        for (uint256 i = _offset; i < end; ) {
            pairsInfo[i - _offset] = pairInfo[pairs[i]];

            // gas savings
            unchecked {
                ++i;
            }
        }
        return (pairsInfo, end < pairs.length);
    }

    // =========================================
    // Admin Functions
    // =========================================

    /**
     * @notice Updates the AllowListHook address.
     * @param _newAllowListHook The new AllowListHook address.
     */
    function setAllowListHook(address _newAllowListHook) external onlyOwner {
        require(_newAllowListHook != address(0), "Invalid address");

        allowListHook = IAllowListHook(_newAllowListHook);
        emit AllowListHookUpdated(_newAllowListHook);
    }

    /**
     * @notice Updates the SudoVRFRouter address, also updates allow list hook and all buy pairs with new router address.
     * @param _newSudoVRFRouter The new SudoVRFRouter address.
     * @param _pairOffset The offset of the pairs to update.
     * @param _pairLimit The limit of the pairs to update. Set to 0 to not update.
     * @param _allowListOffset The offset of the allow list to update.
     * @param _allowListLimit The limit of the allow list to update. Set to 0 to not update.
     */
    function updateSudoVRFRouterConfig(
        address payable _newSudoVRFRouter,
        uint256 _pairOffset,
        uint256 _pairLimit,
        uint256 _allowListOffset,
        uint256 _allowListLimit
    ) external onlyOwner {
        require(_newSudoVRFRouter != address(0), "Invalid new router");

        sudoVRFRouter = _newSudoVRFRouter;

        if (_allowListLimit != 0) {
            // AllowListHook already checks if offset is valid
            allowListHook.updateAllowListWithNewRouter(
                _newSudoVRFRouter,
                _allowListOffset,
                _allowListLimit
            );
        }

        // Update only buy pairs with new asset recipient
        if (_pairLimit != 0) {
            require(_pairOffset < buyPairs.length, "Invalid pair offset");
            uint256 end = _pairOffset + _pairLimit > buyPairs.length
                ? buyPairs.length
                : _pairOffset + _pairLimit;
            for (uint256 i = _pairOffset; i < end; ) {
                ILSSVMPair(buyPairs[i]).changeAssetRecipient(
                    payable(_newSudoVRFRouter)
                );

                // gas savings
                unchecked {
                    ++i;
                }
            }
        }

        emit SudoVRFRouterConfigUpdated(
            _newSudoVRFRouter,
            _pairOffset,
            _pairLimit,
            _allowListOffset,
            _allowListLimit
        );
    }

    /**
     * @notice Updates the minimum lock duration.
     * @param _newMinimumLockDuration The new minimum lock duration.
     */
    function setMinimumLockDuration(
        uint256 _newMinimumLockDuration
    ) external onlyOwner {
        require(
            _newMinimumLockDuration >= MIN_LOCK_DURATION,
            "Lock duration too short"
        );

        minimumLockDuration = _newMinimumLockDuration;
        emit MinimumLockDurationUpdated(_newMinimumLockDuration);
    }

    // =========================================
    // Internal Functions
    // =========================================

    /**
     * @notice Creates an ERC721-ETH pair.
     * @param _params The CreatePairParams for creating the pair.
     * @return pairAddress Address of the created pair.
     */
    function _createERC721ETHPair(
        CreatePairParams memory _params
    ) internal returns (address pairAddress) {
        IERC721 nft = IERC721(_params.nft);
        // Transfer initial NFTs and approve factory if pool is a sell pool
        if (!_params.isBuy && _params.initialNFTIDs.length > 0) {
            _transferERC721Tokens(
                _params.sender,
                address(this),
                nft,
                _params.initialNFTIDs
            );
            nft.setApprovalForAll(address(factory), true);
        }

        // Determine pool type
        ILSSVMPair.PoolType poolType = _params.isBuy
            ? ILSSVMPair.PoolType.TOKEN
            : ILSSVMPair.PoolType.NFT;

        ILSSVMPair pair = factory.createPairERC721ETH{value: msg.value}(
            nft,
            ICurve(_params.bondingCurve),
            _params.isBuy ? payable(sudoVRFRouter) : payable(_params.sender), // If a buy pool, set asset recipient to sudoVRFRouter for AllowListHook to work
            poolType,
            _params.delta,
            0,
            _params.spotPrice,
            address(0),
            _params.isBuy ? new uint256[](0) : _params.initialNFTIDs,
            address(allowListHook),
            address(0)
        );

        // Set random pair if sell pool and isRandom
        isRandomPair[address(pair)] = !_params.isBuy && _params.isRandom;

        // Update pair info and emit event
        _finalizePairCreation(
            _params.sender,
            pair,
            _params.initialNFTIDs,
            _params.lockDuration,
            true,
            true,
            _params.isBuy,
            _params.isRandom
        );

        return address(pair);
    }

    /**
     * @notice Creates an ERC721-ERC20 pair.
     * @param _params The CreatePairParams for creating the pair.
     * @return pairAddress Address of the created pair.
     */
    function _createERC721ERC20Pair(
        CreatePairParams memory _params
    ) internal returns (address pairAddress) {
        IERC721 nft = IERC721(_params.nft);
        ERC20 token = ERC20(_params.token);

        // Transfer initial NFTs and approve factory if pool is a sell pool
        if (!_params.isBuy && _params.initialNFTIDs.length > 0) {
            _transferERC721Tokens(
                _params.sender,
                address(this),
                nft,
                _params.initialNFTIDs
            );
            nft.setApprovalForAll(address(factory), true);
        }

        // Transfer initial ERC20 tokens and approve factory
        if (_params.initialTokenBalance > 0) {
            token.safeTransferFrom(
                _params.sender,
                address(this),
                _params.initialTokenBalance
            );
            token.safeApprove(address(factory), _params.initialTokenBalance);
        }

        // Determine pool type
        ILSSVMPair.PoolType poolType = _params.isBuy
            ? ILSSVMPair.PoolType.TOKEN
            : ILSSVMPair.PoolType.NFT;

        ILSSVMPairFactory.CreateERC721ERC20PairParams memory params = ILSSVMPairFactory
            .CreateERC721ERC20PairParams({
                token: token,
                nft: nft,
                bondingCurve: ICurve(_params.bondingCurve),
                assetRecipient: _params.isBuy // If a buy pool, set asset recipient to sudoVRFRouter for AllowListHook to work
                    ? payable(sudoVRFRouter)
                    : payable(_params.sender),
                poolType: poolType,
                delta: _params.delta,
                fee: 0,
                spotPrice: _params.spotPrice,
                propertyChecker: address(0),
                initialNFTIDs: _params.isBuy
                    ? new uint256[](0)
                    : _params.initialNFTIDs,
                initialTokenBalance: _params.isBuy
                    ? _params.initialTokenBalance
                    : 0,
                hookAddress: address(allowListHook),
                referralAddress: address(0)
            });
        ILSSVMPair pair = factory.createPairERC721ERC20(params);

        // Set random pair if sell pool and isRandom
        isRandomPair[address(pair)] = !_params.isBuy && _params.isRandom;

        // Update pair info and emit event
        _finalizePairCreation(
            _params.sender,
            pair,
            _params.initialNFTIDs,
            _params.lockDuration,
            true,
            false,
            _params.isBuy,
            _params.isRandom
        );

        return address(pair);
    }

    /**
     * @notice Creates an ERC1155-ETH pair.
     * @param _params The CreatePairParams for creating the pair.
     * @return pairAddress Address of the created pair.
     */
    function _createERC1155ETHPair(
        CreatePairParams memory _params
    ) internal returns (address pairAddress) {
        IERC1155 nft = IERC1155(_params.nft);

        // Transfer initial NFT amount and approve factory if pool is a sell pool
        if (!_params.isBuy && _params.initialNFTBalance > 0) {
            nft.safeTransferFrom(
                _params.sender,
                address(this),
                _params.initialNFTIDs[0],
                _params.initialNFTBalance,
                bytes("")
            );
            nft.setApprovalForAll(address(factory), true);
        }

        // Determine pool type
        ILSSVMPair.PoolType poolType = _params.isBuy
            ? ILSSVMPair.PoolType.TOKEN
            : ILSSVMPair.PoolType.NFT;

        ILSSVMPair pair = factory.createPairERC1155ETH{value: msg.value}(
            nft,
            ICurve(_params.bondingCurve),
            _params.isBuy ? payable(sudoVRFRouter) : payable(_params.sender), // If a buy pool, set asset recipient to sudoVRFRouter for AllowListHook to work
            poolType,
            _params.delta,
            0,
            _params.spotPrice,
            _params.initialNFTIDs[0],
            _params.isBuy ? 0 : _params.initialNFTBalance,
            address(allowListHook),
            address(0)
        );

        // Update pair info and emit event
        _finalizePairCreation(
            _params.sender,
            pair,
            _params.initialNFTIDs,
            _params.lockDuration,
            false,
            true,
            _params.isBuy,
            false
        );

        return address(pair);
    }

    /**
     * @notice Creates an ERC1155-ERC20 pair.
     * @param _params The CreatePairParams for creating the pair.
     * @return pairAddress Address of the created pair.
     */
    function _createERC1155ERC20Pair(
        CreatePairParams memory _params
    ) internal returns (address pairAddress) {
        IERC1155 nft = IERC1155(_params.nft);
        ERC20 token = ERC20(_params.token);

        // Transfer initial NFT amount and approve factory if pool is a sell pool
        if (!_params.isBuy && _params.initialNFTBalance > 0) {
            nft.safeTransferFrom(
                _params.sender,
                address(this),
                _params.initialNFTIDs[0],
                _params.initialNFTBalance,
                bytes("")
            );
            nft.setApprovalForAll(address(factory), true);
        }

        // Transfer initial ERC20 tokens and approve factory
        if (_params.initialTokenBalance > 0) {
            token.safeTransferFrom(
                _params.sender,
                address(this),
                _params.initialTokenBalance
            );
            token.safeApprove(address(factory), _params.initialTokenBalance);
        }

        // Determine pool type
        ILSSVMPair.PoolType poolType = _params.isBuy
            ? ILSSVMPair.PoolType.TOKEN
            : ILSSVMPair.PoolType.NFT;

        ILSSVMPairFactory.CreateERC1155ERC20PairParams memory params = ILSSVMPairFactory
            .CreateERC1155ERC20PairParams({
                token: token,
                nft: nft,
                bondingCurve: ICurve(_params.bondingCurve),
                assetRecipient: _params.isBuy // If a buy pool, set asset recipient to sudoVRFRouter for AllowListHook to work
                    ? payable(sudoVRFRouter)
                    : payable(_params.sender),
                poolType: poolType,
                delta: _params.delta,
                fee: 0,
                spotPrice: _params.spotPrice,
                nftId: _params.initialNFTIDs[0],
                initialNFTBalance: _params.isBuy
                    ? 0
                    : _params.initialNFTBalance,
                initialTokenBalance: _params.isBuy
                    ? _params.initialTokenBalance
                    : 0,
                hookAddress: address(allowListHook),
                referralAddress: address(0)
            });
        ILSSVMPair pair = factory.createPairERC1155ERC20(params);

        // Update pair info and emit event
        _finalizePairCreation(
            _params.sender,
            pair,
            _params.initialNFTIDs,
            _params.lockDuration,
            false,
            false,
            _params.isBuy,
            false
        );

        return address(pair);
    }

    /**
     * @notice Finalizes the pair creation by setting up allow lists and approvals.
     * @param _sender Address that created the pair.
     * @param _pair The newly created LSSVMPair.
     * @param _initialNFTIDs Array of initial NFT IDs added to the pair.
     * @param _lockDuration Duration for which the pair is locked.
     * @param _isERC721 Boolean indicating if the pair is for ERC721 NFTs.
     * @param _isETH Boolean indicating if the pair is an ETH pair.
     * @param _isBuy Boolean indicating if the pair is a buy pool.
     * @param _isRandom Boolean indicating if the pair is a random pair (only for ERC721 buy pools).
     */
    function _finalizePairCreation(
        address _sender,
        ILSSVMPair _pair,
        uint256[] memory _initialNFTIDs,
        uint256 _lockDuration,
        bool _isERC721,
        bool _isETH,
        bool _isBuy,
        bool _isRandom
    ) internal {
        address nft = _pair.nft();
        // Set up the allow list for the newly created pair
        allowListHook.modifyAllowListSingleBuyer(_initialNFTIDs, sudoVRFRouter);

        // Set the address, unlock time, creator, and withdrawal status for the pair
        uint256 unlockTime = block.timestamp + _lockDuration;
        pairInfo[address(_pair)] = PairInfo({
            pairAddress: address(_pair),
            pairUnlockTime: unlockTime,
            pairCreator: _sender,
            hasWithdrawn: false
        });
        pairsByCreator[_sender].push(address(_pair));
        isPair[address(_pair)] = true;
        // Add to buyPairs if buy pool
        if (_isBuy) {
            buyPairs.push(address(_pair));
        }

        // Revoke approvals after pair creation to enhance security
        if (_initialNFTIDs.length > 0) {
            if (_isERC721) {
                IERC721(nft).setApprovalForAll(address(factory), false);
            } else {
                IERC1155(nft).setApprovalForAll(address(factory), false);
            }
        }

        emit PairCreated(
            address(_pair),
            _sender,
            unlockTime,
            _isERC721,
            _isETH,
            _isBuy,
            _isRandom
        );
    }

    /**
     * @notice Withdraws assets from a pair and transfers them to the owner.
     * @param pair The LSSVMPair to withdraw from.
     * @param nft The address of the NFT contract.
     * @param sender The address of the pair creator.
     * @return nftIds The IDs of the NFTs withdrawn.
     * @return amountTokenOrETH The amount of tokens or ETH withdrawn.
     * @return amountERC1155 The amount of ERC1155 NFTs withdrawn (0 for ERC721).
     */
    function _withdrawAssets(
        ILSSVMPair pair,
        address nft,
        address sender
    )
        internal
        returns (
            uint256[] memory nftIds,
            uint256 amountTokenOrETH,
            uint256 amountERC1155
        )
    {
        // Withdraw tokens or ETH
        if (_isETHPair(pair)) {
            // Withdraw ETH from pair
            amountTokenOrETH = address(pair).balance;
            if (amountTokenOrETH > 0) {
                pair.withdrawETH(amountTokenOrETH);
                payable(sender).safeTransferETH(amountTokenOrETH);
            }
        } else {
            // Withdraw ERC20 tokens from pair
            ERC20 token = pair.token();
            amountTokenOrETH = token.balanceOf(address(pair));
            if (amountTokenOrETH > 0) {
                pair.withdrawERC20(token, amountTokenOrETH);
                token.safeTransfer(sender, amountTokenOrETH);
            }
        }

        // Withdraw NFTs
        if (_isERC721Pair(pair)) {
            // Withdraw ERC721 NFTs
            nftIds = pair.getAllIds();
            amountERC1155 = 0;

            pair.withdrawERC721(IERC721(nft), nftIds);
            _transferERC721Tokens(address(this), sender, IERC721(nft), nftIds);
        } else {
            // Withdraw ERC1155 NFTs
            nftIds = new uint256[](1);
            nftIds[0] = pair.nftId();
            uint256[] memory amountsERC1155 = new uint256[](1);
            amountsERC1155[0] = IERC1155(nft).balanceOf(
                address(pair),
                nftIds[0]
            );
            amountERC1155 = amountsERC1155[0];

            pair.withdrawERC1155(IERC1155(nft), nftIds, amountsERC1155);
            IERC1155(nft).safeBatchTransferFrom(
                address(this),
                sender,
                nftIds,
                amountsERC1155,
                bytes("")
            );
        }

        return (nftIds, amountTokenOrETH, amountERC1155);
    }

    /**
     * @notice Transfers multiple ERC721 tokens from one address to another.
     * @param _from Address to transfer tokens from.
     * @param _to Address to transfer tokens to.
     * @param _nftContract Address of the ERC721 contract.
     * @param _tokenIDs Array of token IDs to transfer.
     */
    function _transferERC721Tokens(
        address _from,
        address _to,
        IERC721 _nftContract,
        uint256[] memory _tokenIDs
    ) internal {
        for (uint256 i = 0; i < _tokenIDs.length; ) {
            _nftContract.safeTransferFrom(_from, _to, _tokenIDs[i]);

            // Gas savings
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Checks if a contract supports a given interface.
     * @param _contract Address of the contract to check.
     * @param _interfaceId Interface ID to check.
     * @return True if the contract supports the interface.
     */
    function _supportsInterface(
        address _contract,
        bytes4 _interfaceId
    ) internal view returns (bool) {
        return IERC165(_contract).supportsInterface(_interfaceId);
    }

    /**
     * @notice Checks if a pair is an ETH pair.
     * @param pair The LSSVMPair to check.
     * @return True if the pair is an ETH pair.
     */
    function _isETHPair(ILSSVMPair pair) internal pure returns (bool) {
        return
            pair.pairVariant() == ILSSVMPairFactory.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactory.PairVariant.ERC1155_ETH;
    }

    /**
     * @notice Checks if a pair is an ERC721 pair.
     * @param pair The LSSVMPair to check.
     * @return True if the pair is an ERC721 pair.
     */
    function _isERC721Pair(ILSSVMPair pair) internal pure returns (bool) {
        return
            pair.pairVariant() == ILSSVMPairFactory.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactory.PairVariant.ERC721_ERC20;
    }
}
