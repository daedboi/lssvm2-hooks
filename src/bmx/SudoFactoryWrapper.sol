// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {ILSSVMPairFactory, ILSSVMPair, ICurve, IAllowListHook} from "./Interfaces.sol";

/**
 * @title SudoFactoryWrapper
 * @author 0xdaedboi
 * @notice A wrapper contract for managing SudoSwap v2 ERC721-ERC20 pair creation and withdrawals with additional features like locking.
 * @dev This contract provides a higher-level interface for creating and managing SudoSwap ERC721-ERC20 pairs only, with added lock mechanisms and access control.
 */
contract SudoFactoryWrapper is Ownable2Step, ReentrancyGuard, ERC721Holder {
    using SafeTransferLib for ERC20;

    // =========================================
    // Constants and Immutable Variables
    // =========================================

    /// @notice Minimum lock duration for a pair (12 hours)
    uint256 public constant MIN_LOCK_DURATION = 12 hours;

    /// @notice Maximum lock duration for a pair (30 days)
    uint256 public constant MAX_LOCK_DURATION = 30 days;

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
    uint256 public minLockDuration;

    /// @notice Maximum duration that a pair can be locked
    uint256 public maxLockDuration;

    /// @notice Total whitelisted token count
    uint256 public whitelistedTokenCount;

    /// @notice Array of all buy pairs created by this factory wrapper.
    /// @dev Used to update all asset recipients for buy pairs when sudoVRFRouter is updated.
    address[] public buyPairs;

    /// @notice Mapping to store if a token is whitelisted
    mapping(address => bool) public isWhitelistedToken;

    /// @notice Mapping to store pair information
    mapping(address => PairInfo) public pairInfo;

    /// @notice Mapping to store pair addresses created by a user
    mapping(address => address[]) public pairsByCreator;

    /// @notice Mapping to store if an address is a pair created by this factory wrapper
    mapping(address => bool) public isPair;

    /// @notice Mapping to store if a pair is a random pair (VRF ERC721 sell pool)
    mapping(address => bool) public isRandomPair;

    // =========================================
    // Structs
    // =========================================

    /// @notice Struct to store pair information
    struct PairInfo {
        uint256 pairUnlockTime; // Timestamp when the pair will be unlocked
        address pairCreator; // Address of the pair creator
        bool hasWithdrawn; // Whether the pair has been withdrawn from
    }

    /// @notice Struct to store create pair parameters
    struct CreatePairParams {
        address sender;
        bool isBuy;
        address nft;
        address token;
        address bondingCurve;
        uint128 delta;
        uint128 spotPrice;
        uint256 lockDuration;
        uint256[] initialNFTIDs;
        uint256 initialTokenBalance;
    }

    // =========================================
    // Events
    // =========================================

    event PairCreated(
        address indexed pair,
        address indexed creator,
        uint256 unlockTime,
        bool isBuy
    );
    event PairWithdrawal(address indexed pair, address indexed withdrawer);
    event AllowListHookUpdated(address newAllowListHook);
    event SudoVRFRouterConfigUpdated(
        address newSudoVRFRouter,
        uint256 pairOffset,
        uint256 pairLimit
    );
    event LockDurationsUpdated(
        uint256 newMinimumLockDuration,
        uint256 newMaximumLockDuration
    );
    event WhitelistedTokensUpdated(address[] newWhitelistedTokens, bool isAdd);

    // =========================================
    // Constructor
    // =========================================

    /**
     * @param _factory Address of the LSSVMPairFactory.
     * @param _minLockDuration Minimum lock duration for a pair.
     * @param _maxLockDuration Maximum lock duration for a pair.
     * @param _whitelistedTokens Array of all whitelisted tokens.
     */
    constructor(
        address _factory,
        uint256 _minLockDuration,
        uint256 _maxLockDuration,
        address[] memory _whitelistedTokens
    ) {
        require(_factory != address(0), "Invalid factory address");
        require(
            _minLockDuration >= MIN_LOCK_DURATION &&
                _minLockDuration < _maxLockDuration,
            "Invalid minimum lock duration"
        );
        require(
            _maxLockDuration <= MAX_LOCK_DURATION,
            "Maximum lock duration too long"
        );
        for (uint256 i = 0; i < _whitelistedTokens.length; ) {
            require(
                _whitelistedTokens[i] != address(0),
                "Invalid token address"
            );
            isWhitelistedToken[_whitelistedTokens[i]] = true;

            unchecked {
                ++i;
            }
        }

        factory = ILSSVMPairFactory(payable(_factory));
        minLockDuration = _minLockDuration;
        maxLockDuration = _maxLockDuration;
        whitelistedTokenCount = _whitelistedTokens.length;
    }

    receive() external payable {
        revert("ETH not accepted");
    }

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Creates a new locked ERC721-ERC20 pair.
     * @dev ETH is not supported.
     * @param _isBuy Determines if the ERC721 pair is a buy or sell pair.
     * @param _nft Address of the NFT contract.
     * @param _token Address of the ERC20 token.
     * @param _bondingCurve Address of the bonding curve contract.
     * @param _delta Delta parameter for the bonding curve.
     * @param _spotPrice Initial spot price for the pair.
     * @param _lockDuration Duration for which the pair is locked.
     * @param _initialNFTIDs Array of initial NFT IDs to be added for ERC7721.
     * @param _initialTokenBalance Initial token balance to be added.
     * @return pairAddress Address of the created pair.
     */
    function createPair(
        bool _isBuy,
        address _nft,
        address _token,
        address _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs,
        uint256 _initialTokenBalance
    ) external nonReentrant returns (address pairAddress) {
        require(
            _nft != address(0) &&
                _bondingCurve != address(0) &&
                _token != address(0),
            "Invalid NFT, bonding curve or token address"
        );
        require(
            _lockDuration >= minLockDuration &&
                _lockDuration <= maxLockDuration,
            "Invalid lock duration"
        );
        require(isWhitelistedToken[_token], "Token not whitelisted");

        // Check if NFT is ERC721
        if (IERC165(_nft).supportsInterface(type(IERC721).interfaceId)) {
            pairAddress = _createERC721ERC20Pair(
                CreatePairParams(
                    msg.sender,
                    _isBuy,
                    _nft,
                    _token,
                    _bondingCurve,
                    _delta,
                    _spotPrice,
                    _lockDuration,
                    _initialNFTIDs,
                    _initialTokenBalance
                )
            );
        }
        // Invalid NFT
        else {
            revert("Must be ERC721");
        }

        return pairAddress;
    }

    /**
     * @notice Withdraws the specified pair for a user after lock duration.
     * @dev Transfers ownership of the pair to the user.
     * @param _pair Address of the pair to withdraw.
     */
    function withdrawPair(address _pair) external nonReentrant {
        require(_pair != address(0) && isPair[_pair], "Invalid pair address");

        address sender = msg.sender;
        PairInfo memory info = pairInfo[_pair];
        ILSSVMPair pair = ILSSVMPair(_pair);

        require(sender == info.pairCreator, "Only the creator can withdraw");
        require(info.hasWithdrawn == false, "Pair already withdrawn");
        require(block.timestamp >= info.pairUnlockTime, "Pair is still locked");

        pairInfo[_pair].hasWithdrawn = true;
        pair.transferOwnership(sender, "");

        emit PairWithdrawal(_pair, sender);
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

    function updateWhitelistedTokens(
        address[] calldata _whitelistedTokens,
        bool _isAdd
    ) external onlyOwner {
        require(_whitelistedTokens.length > 0, "No whitelisted tokens");
        for (uint256 i = 0; i < _whitelistedTokens.length; ) {
            require(
                _whitelistedTokens[i] != address(0),
                "Invalid token address"
            );
            if (_isAdd) {
                require(
                    !isWhitelistedToken[_whitelistedTokens[i]],
                    "Token already whitelisted"
                );

                isWhitelistedToken[_whitelistedTokens[i]] = true;
                whitelistedTokenCount++;
            } else {
                require(
                    isWhitelistedToken[_whitelistedTokens[i]],
                    "Token not whitelisted"
                );

                isWhitelistedToken[_whitelistedTokens[i]] = false;
                whitelistedTokenCount--;
            }

            unchecked {
                ++i;
            }
        }

        emit WhitelistedTokensUpdated(_whitelistedTokens, _isAdd);
    }

    /**
     * @notice Updates the SudoVRFRouter address, also updates allow list hook and all buy pairs with new router address.
     * @param _newSudoVRFRouter The new SudoVRFRouter address.
     * @param _pairOffset The offset of the pairs to update.
     * @param _pairLimit The limit of the pairs to update. Set to 0 to not update.
     */
    function updateSudoVRFRouterConfig(
        address _newSudoVRFRouter,
        uint256 _pairOffset,
        uint256 _pairLimit
    ) external onlyOwner {
        require(_newSudoVRFRouter != address(0), "Invalid new router");

        sudoVRFRouter = _newSudoVRFRouter;
        allowListHook.updateAllowListWithNewRouter(_newSudoVRFRouter);

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
            _pairLimit
        );
    }

    /**
     * @notice Updates the minimum and maximum lock duration.
     * @param _newMinLockDuration The new minimum lock duration.
     * @param _newMaxLockDuration The new maximum lock duration.
     */
    function setLockDurations(
        uint256 _newMinLockDuration,
        uint256 _newMaxLockDuration
    ) external onlyOwner {
        require(
            _newMinLockDuration >= MIN_LOCK_DURATION &&
                _newMinLockDuration < _newMaxLockDuration,
            "Invalid minimum lock duration"
        );
        require(
            _newMaxLockDuration <= MAX_LOCK_DURATION,
            "Invalid maximum lock duration"
        );

        minLockDuration = _newMinLockDuration;
        maxLockDuration = _newMaxLockDuration;
        emit LockDurationsUpdated(_newMinLockDuration, _newMaxLockDuration);
    }

    // =========================================
    // Internal Functions
    // =========================================

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
            for (uint256 i = 0; i < _params.initialNFTIDs.length; ) {
                nft.safeTransferFrom(
                    _params.sender,
                    address(this),
                    _params.initialNFTIDs[i]
                );

                // Gas savings
                unchecked {
                    ++i;
                }
            }
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

        // Set random pair if sell pool
        isRandomPair[address(pair)] = !_params.isBuy;

        // Update pair info and emit event
        _finalizePairCreation(
            _params.sender,
            pair,
            _params.initialNFTIDs,
            _params.lockDuration,
            _params.isBuy
        );

        return address(pair);
    }

    /**
     * @notice Finalizes the pair creation by setting up allow lists and approvals.
     * @param _sender Address that created the pair.
     * @param _pair The newly created LSSVMPair.
     * @param _initialNFTIDs Array of initial NFT IDs added to the pair.
     * @param _lockDuration Duration for which the pair is locked.
     * @param _isBuy Boolean indicating if the pair is a buy pool.
     */
    function _finalizePairCreation(
        address _sender,
        ILSSVMPair _pair,
        uint256[] memory _initialNFTIDs,
        uint256 _lockDuration,
        bool _isBuy
    ) internal {
        // Set the address, unlock time, creator, and withdrawal status for the pair
        uint256 unlockTime = block.timestamp + _lockDuration;
        pairInfo[address(_pair)] = PairInfo({
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
            IERC721(_pair.nft()).setApprovalForAll(address(factory), false);
        }

        emit PairCreated(address(_pair), _sender, unlockTime, _isBuy);
    }
}
