// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {ILSSVMPairFactory, ILSSVMPair, ICurve} from "./Interfaces.sol";

/**
 * @title SudoFactoryWrapper
 * @author 0xdaedboi
 * @notice A wrapper contract for managing single-asset SudoSwap v2 ERC721-ERC20 pair creation and withdrawals with additional features like locking.
 * @dev This contract provides a higher-level interface for creating and managing single-asset SudoSwap ERC721-ERC20 pairs only, with added lock mechanisms and access control.
 */
contract SudoSingleFactoryWrapper is
    Ownable2Step,
    ReentrancyGuard,
    ERC721Holder
{
    using SafeTransferLib for ERC20;

    // =========================================
    // Constants and Immutable Variables
    // =========================================

    /// @notice Maximum lock duration for a pair (30 days)
    uint256 public constant MAX_LOCK_DURATION = 30 days;

    /// @notice Factory instance to create pairs
    ILSSVMPairFactory public immutable factory;

    /// @notice Linear bonding curve instance
    ICurve public immutable bondingCurve;

    // =========================================
    // State Variables
    // =========================================

    /// @notice Address of the AllowListHook for managing allowed addresses
    address public allowListHook;

    /// @notice Minimum duration that a pair must remain locked
    uint256 public minLockDuration;

    /// @notice Maximum duration that a pair can be locked
    uint256 public maxLockDuration;

    /// @notice Total whitelisted token count
    uint256 public whitelistedTokenCount;

    /// @notice Mapping to store if a token is whitelisted
    mapping(address => bool) public isWhitelistedToken;

    /// @notice Mapping to store pair information
    mapping(address => PairInfo) public pairInfo;

    /// @notice Mapping to store pair addresses created by a user
    mapping(address => address[]) public pairsByCreator;

    /// @notice Mapping to store if an address is a pair created by this factory wrapper
    mapping(address => bool) public isPair;

    // =========================================
    // Structs
    // =========================================

    /// @notice Struct to store pair information
    struct PairInfo {
        uint256 pairUnlockTime; // Timestamp when the pair will be unlocked
        address pairCreator; // Address of the pair creator
        bool hasWithdrawn; // Whether the pair has been withdrawn from
    }

    // =========================================
    // Events
    // =========================================

    event PairCreated(
        address indexed pair,
        address indexed creator,
        uint256 unlockTime
    );
    event PairWithdrawal(address indexed pair, address indexed withdrawer);
    event AllowListHookUpdated(address newAllowListHook);
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
     * @param _bondingCurve Address of the bonding curve.
     * @param _minLockDuration Minimum lock duration for a pair.
     * @param _maxLockDuration Maximum lock duration for a pair.
     * @param _whitelistedTokens Array of all whitelisted tokens.
     */
    constructor(
        address _factory,
        address _bondingCurve,
        uint256 _minLockDuration,
        uint256 _maxLockDuration,
        address[] memory _whitelistedTokens
    ) {
        require(
            _factory != address(0) && _bondingCurve != address(0),
            "Invalid factory or bonding curve address"
        );
        require(
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
        bondingCurve = ICurve(_bondingCurve);
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
     * @notice Creates a new locked single-asset ERC721-ERC20 pair for selling NFTs.
     * @dev ETH is not supported.
     * @param _nft Address of the NFT contract.
     * @param _token Address of the ERC20 token.
     * @param _spotPrice Initial spot price for the pair.
     * @param _lockDuration Duration for which the pair is locked.
     * @param _nftID Initial NFT ID to be added for ERC721.
     * @return pairAddress Address of the created pair.
     */
    function createPair(
        address _nft,
        address _token,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256 _nftID
    ) external nonReentrant returns (address pairAddress) {
        require(
            _nft != address(0) && _token != address(0),
            "Invalid NFT or token address"
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
                msg.sender,
                _nft,
                _token,
                _spotPrice,
                _lockDuration,
                _nftID
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
        require(
            block.timestamp >= info.pairUnlockTime || info.pairUnlockTime == 0,
            "Pair is still locked"
        );

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

        allowListHook = _newAllowListHook;
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
     * @notice Updates the minimum and maximum lock duration.
     * @param _newMinLockDuration The new minimum lock duration.
     * @param _newMaxLockDuration The new maximum lock duration.
     */
    function setLockDurations(
        uint256 _newMinLockDuration,
        uint256 _newMaxLockDuration
    ) external onlyOwner {
        require(
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
     * @param _sender Address that created the pair.
     * @param _nft Address of the NFT contract.
     * @param _token Address of the ERC20 token.
     * @param _spotPrice Initial spot price for the pair.
     * @param _lockDuration Duration for which the pair is locked.
     * @param _nftID Initial NFT ID to be added for ERC721.
     * @return pairAddress Address of the created pair.
     */
    function _createERC721ERC20Pair(
        address _sender,
        address _nft,
        address _token,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256 _nftID
    ) internal returns (address pairAddress) {
        IERC721 nft = IERC721(_nft);
        ERC20 token = ERC20(_token);
        uint256[] memory initialNFTIDs = new uint256[](1);
        initialNFTIDs[0] = _nftID;

        // Transfer initial NFT and approve factory
        nft.safeTransferFrom(_sender, address(this), _nftID);
        nft.approve(address(factory), _nftID);

        ILSSVMPairFactory.CreateERC721ERC20PairParams
            memory params = ILSSVMPairFactory.CreateERC721ERC20PairParams({
                token: token,
                nft: nft,
                bondingCurve: bondingCurve,
                assetRecipient: payable(_sender),
                poolType: ILSSVMPair.PoolType.NFT,
                delta: 0,
                fee: 0,
                spotPrice: _spotPrice,
                propertyChecker: address(0),
                initialNFTIDs: initialNFTIDs,
                initialTokenBalance: 0,
                hookAddress: allowListHook,
                referralAddress: address(0)
            });
        ILSSVMPair pair = factory.createPairERC721ERC20(params);

        // Update pair info and emit event
        _finalizePairCreation(_sender, pair, _lockDuration);

        return address(pair);
    }

    /**
     * @notice Finalizes the pair creation by setting up allow lists and approvals.
     * @param _sender Address that created the pair.
     * @param _pair The newly created LSSVMPair.
     * @param _lockDuration Duration for which the pair is locked.
     */
    function _finalizePairCreation(
        address _sender,
        ILSSVMPair _pair,
        uint256 _lockDuration
    ) internal {
        // Set the address, unlock time, creator, and withdrawal status for the pair
        uint256 unlockTime = _lockDuration == 0
            ? 0
            : block.timestamp + _lockDuration;
        pairInfo[address(_pair)] = PairInfo({
            pairUnlockTime: unlockTime,
            pairCreator: _sender,
            hasWithdrawn: false
        });
        pairsByCreator[_sender].push(address(_pair));
        isPair[address(_pair)] = true;

        emit PairCreated(address(_pair), _sender, unlockTime);
    }
}
