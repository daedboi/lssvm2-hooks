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

import {LSSVMPairFactory} from "../LSSVMPairFactory.sol";
import {ILSSVMPairFactoryLike} from "../ILSSVMPairFactoryLike.sol";
import {LSSVMPair} from "../LSSVMPair.sol";
import {LSSVMPairETH} from "../LSSVMPairETH.sol";
import {LSSVMPairERC721} from "../erc721/LSSVMPairERC721.sol";
import {LSSVMPairERC1155} from "../erc1155/LSSVMPairERC1155.sol";
import {ILSSVMPair} from "../ILSSVMPair.sol";
import {ICurve} from "../bonding-curves/ICurve.sol";
import {AllowListHook} from "../hooks/AllowListHook.sol";

/// @title SudoFactoryWrapper
/// @author 0xdaedboi
/// @notice Wrapper contract for managing SudoSwap v2 pair creation and withdrawals with additional features.
contract SudoFactoryWrapper is
    Ownable,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder
{
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;

    /// @notice Minimum lock duration for a pair
    uint256 public constant MIN_LOCK_DURATION = 12 hours;
    /// @notice Factory instance to create pairs
    LSSVMPairFactory public immutable factory;

    /// @notice Instance of the AllowListHook for managing allowed addresses
    AllowListHook public allowListHook;
    /// @notice Address of the SudoWrapper contract (for buying and selling NFTs, needs to be whitelisted in AllowListHook)
    address public sudoWrapper;
    /// @notice Minimum duration that a pair must remain locked
    uint256 public minimumLockDuration;

    /// @notice Struct to store pair information
    struct PairInfo {
        /// @notice Pair address
        address pairAddress;
        /// @notice Timestamp when the pair will be unlocked
        uint256 pairUnlockTime;
        /// @notice Address of the pair creator
        address pairCreator;
        /// @notice Whether the pair has been withdrawn from
        bool hasWithdrawn;
    }

    /// @notice Mapping to store pair information (address, unlockTime, creator, hasWithdrawn)
    mapping(address => PairInfo) public pairInfo;
    /// @notice Mapping to store pair addresses created by a user
    mapping(address => address[]) public pairsByCreator;

    // Events
    event PairCreated(
        address indexed pair,
        address indexed creator,
        uint256 unlockTime
    );
    event PairWithdrawal(
        address indexed pair,
        address indexed withdrawer,
        uint256[] nftIds,
        uint256 amountTokenOrETH,
        uint256 amountERC1155
    );
    event AllowListHookUpdated(address newAllowListHook);
    event SudoWrapperUpdated(address newSudoWrapper);
    event MinimumLockDurationUpdated(uint256 newMinimumLockDuration);

    /// @notice Initializes the contract with factory and allow list hook.
    /// @param _factory Address of the LSSVMPairFactory.
    /// @param _allowListHook Address of the AllowListHook.
    /// @param _minimumLockDuration Minimum lock duration for a pair.
    constructor(
        address _factory,
        address _allowListHook,
        uint256 _minimumLockDuration,
        address _sudoWrapper
    ) {
        require(
            _factory != address(0) &&
                _allowListHook != address(0) &&
                _sudoWrapper != address(0),
            "Invalid addresses"
        );
        require(
            _minimumLockDuration >= MIN_LOCK_DURATION,
            "Invalid lock duration"
        );
        factory = LSSVMPairFactory(payable(_factory));
        allowListHook = AllowListHook(_allowListHook);
        minimumLockDuration = _minimumLockDuration;
        sudoWrapper = _sudoWrapper;
    }

    /// @notice Allows the contract to receive ETH.
    receive() external payable {}

    // *************** External Functions *************** //

    /// @notice Creates a new pair with specified parameters.
    /// @param isBuy Determines if the pair is a buy or sell pair.
    /// @param _nft Address of the NFT contract.
    /// @param _token Address of the ERC20 token (use address(0) for ETH).
    /// @param _bondingCurve Address of the bonding curve contract.
    /// @param _delta Delta parameter for the bonding curve.
    /// @param _spotPrice Initial spot price for the pair.
    /// @param _lockDuration Duration for which the pair is locked.
    /// @param _initialNFTIDs Array of initial NFT IDs to be added (ERC721).
    /// @param _initialTokenBalance Initial token balance to be added (ERC20).
    /// @param _nftId Specific NFT ID for ERC1155 pairs.
    /// @param _initialNFTBalance Initial NFT balance for ERC1155 pairs.
    /// @return pairAddress Address of the created pair.
    function createPair(
        bool isBuy,
        address _nft,
        address _token,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs,
        uint256 _initialTokenBalance,
        uint256 _nftId,
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

        address sender = msg.sender;
        bool isETH = _token == address(0);
        bool isERC721 = IERC165(_nft).supportsInterface(
            type(IERC721).interfaceId
        );
        bool isERC1155 = IERC165(_nft).supportsInterface(
            type(IERC1155).interfaceId
        );

        require(isERC721 || isERC1155, "Invalid NFT");

        // Check if NFT is ERC721 or ERC1155, then if token is ETH or ERC20
        if (isERC721) {
            if (isETH) {
                pairAddress = _createERC721ETHPair(
                    sender,
                    isBuy,
                    _nft,
                    _bondingCurve,
                    _delta,
                    _spotPrice,
                    _lockDuration,
                    _initialNFTIDs
                );
            } else {
                pairAddress = _createERC721ERC20Pair(
                    sender,
                    isBuy,
                    _nft,
                    _bondingCurve,
                    _delta,
                    _spotPrice,
                    _lockDuration,
                    _initialNFTIDs,
                    _initialTokenBalance,
                    _token
                );
            }
        } else if (isERC1155) {
            if (isETH) {
                pairAddress = _createERC1155ETHPair(
                    sender,
                    isBuy,
                    _nft,
                    _bondingCurve,
                    _delta,
                    _spotPrice,
                    _lockDuration,
                    _nftId,
                    _initialNFTBalance
                );
            } else {
                pairAddress = _createERC1155ERC20Pair(
                    sender,
                    isBuy,
                    _nft,
                    _bondingCurve,
                    _delta,
                    _spotPrice,
                    _lockDuration,
                    _nftId,
                    _initialNFTBalance,
                    _initialTokenBalance,
                    _token
                );
            }
        }

        return pairAddress;
    }

    /// @notice Withdraws all assets from a specified pair after lock duration.
    /// @param _pair Address of the pair to withdraw from.
    /// @return nftIds Array of NFT IDs withdrawn. For ERC1155, only one ID is returned.
    /// @return amountTokenOrETH Amount of ERC20 or ETH withdrawn.
    /// @return amountERC1155 Amount of ERC1155 NFTs withdrawn (0 for ERC721).
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
        address sender = msg.sender;
        PairInfo memory info = pairInfo[_pair];
        LSSVMPair pair = LSSVMPair(_pair); // Basic interface for pair
        address nft = pair.nft();

        require(_pair != address(0), "Invalid pair address");
        require(sender == info.pairCreator, "Only the creator can withdraw");
        require(info.hasWithdrawn == false, "Pair already withdrawn");
        require(block.timestamp >= info.pairUnlockTime, "Pair is still locked");

        // Withdraw tokens or ETH
        if (
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH
        ) {
            // Withdraw ETH from pair
            amountTokenOrETH = address(pair).balance;
            if (amountTokenOrETH > 0) {
                LSSVMPairETH(payable(_pair)).withdrawETH(amountTokenOrETH); // Using LSSVMPairETH(_pair) instead of pair to withdraw ETH from pair
                payable(sender).safeTransferETH(amountTokenOrETH); // Transfer ETH to sender
            }
        } else {
            // Withdraw ERC20 tokens from pair
            ERC20 token = ILSSVMPair(_pair).token(); // Using ILSSVMPair(_pair) instead of pair to get the token
            amountTokenOrETH = token.balanceOf(address(pair));
            if (amountTokenOrETH > 0) {
                pair.withdrawERC20(token, amountTokenOrETH); // Withdraw ERC20 tokens from pair
                token.safeTransfer(sender, amountTokenOrETH); // Transfer ERC20 tokens to sender
            }
        }

        // Withdraw ERC721 or ERC1155 NFTs
        if (
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20
        ) {
            // Withdraw ERC721 NFTs
            nftIds = LSSVMPairERC721(_pair).getAllIds(); // Using LSSVMPairERC721(_pair) instead of pair to get all NFT IDs
            amountERC1155 = 0; // Not applicable for ERC721

            pair.withdrawERC721(IERC721(nft), nftIds); // Withdraw ERC721 NFTs from pair
            _transferERC721Tokens(address(this), sender, nft, nftIds); // Transfer ERC721 NFTs to sender
        } else {
            // Withdraw ERC1155 NFTs
            nftIds = new uint256[](1);
            nftIds[0] = LSSVMPairERC1155(_pair).nftId(); // Using LSSVMPairERC1155(_pair) instead of pair to get the singular NFT ID
            uint256[] memory amountsERC1155 = new uint256[](1); // Required for params
            amountsERC1155[0] = IERC1155(nft).balanceOf(
                address(pair),
                nftIds[0]
            );
            amountERC1155 = amountsERC1155[0]; // For return value + event

            pair.withdrawERC1155(IERC1155(nft), nftIds, amountsERC1155); // Withdraw ERC1155 NFTs from pair
            IERC1155(nft).safeBatchTransferFrom(
                address(this),
                sender,
                nftIds,
                amountsERC1155,
                bytes("")
            ); // Transfer ERC1155 NFTs to sender
        }

        pairInfo[_pair].hasWithdrawn = true; // Prevent further withdrawals

        emit PairWithdrawal(
            _pair,
            sender,
            nftIds,
            amountTokenOrETH,
            amountERC1155
        );

        return (nftIds, amountTokenOrETH, amountERC1155);
    }

    /// @notice Updates the AllowListHook address.
    /// @param _newAllowListHook The new AllowListHook address.
    function setAllowListHook(address _newAllowListHook) external onlyOwner {
        require(_newAllowListHook != address(0), "Invalid address");

        allowListHook = AllowListHook(_newAllowListHook);
        emit AllowListHookUpdated(_newAllowListHook);
    }

    /// @notice Updates the SudoWrapper address.
    /// @param _newSudoWrapper The new SudoWrapper address.
    function setSudoWrapper(address _newSudoWrapper) external onlyOwner {
        require(_newSudoWrapper != address(0), "Invalid address");

        sudoWrapper = _newSudoWrapper;
        emit SudoWrapperUpdated(_newSudoWrapper);
    }

    /// @notice Updates the minimum lock duration.
    /// @param _newMinimumLockDuration The new minimum lock duration.
    function setMinimumLockDuration(
        uint256 _newMinimumLockDuration
    ) external onlyOwner {
        require(_newMinimumLockDuration > 12 hours, "Invalid lock duration");

        minimumLockDuration = _newMinimumLockDuration;
        emit MinimumLockDurationUpdated(_newMinimumLockDuration);
    }

    // *************** View Functions *************** //

    /// @notice Retrieves the unlock time for a specified pair.
    /// @param _pair Address of the pair.
    /// @return The unlock time for the pair.
    function getUnlockTime(address _pair) external view returns (uint256) {
        return pairInfo[_pair].pairUnlockTime;
    }

    /// @notice Retrieves the creator of a specified pair.
    /// @param _pair Address of the pair.
    /// @return The creator of the pair.
    function getPairCreator(address _pair) external view returns (address) {
        return pairInfo[_pair].pairCreator;
    }

    /// @notice Retrieves all pairs created by a specific creator.
    /// @param _creator Address of the creator.
    /// @return An array of PairInfo structs containing pair details.
    function getAllPairsInfoByCreator(
        address _creator
    ) external view returns (PairInfo[] memory) {
        address[] memory pairs = pairsByCreator[_creator];
        PairInfo[] memory pairsInfo = new PairInfo[](pairs.length);
        for (uint256 i = 0; i < pairs.length; ) {
            pairsInfo[i] = pairInfo[pairs[i]];

            unchecked {
                ++i;
            }
        }
        return pairsInfo;
    }

    // *************** Internal Functions *************** //

    /// @notice Creates an ERC721-ETH pair.
    /// @param _sender Address initiating the pair creation.
    /// @param _isBuy Determines if the pair is a buy or sell pool.
    /// @param _nft Address of the ERC721 NFT contract.
    /// @param _bondingCurve Address of the bonding curve contract.
    /// @param _delta Delta parameter for the bonding curve.
    /// @param _spotPrice Initial spot price for the pair.
    /// @param _lockDuration Duration for which the pair is locked.
    /// @param _initialNFTIDs Array of initial ERC721 NFT IDs to add.
    /// @return pairAddress Address of the created pair.
    function _createERC721ETHPair(
        address _sender,
        bool _isBuy,
        address _nft,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs
    ) internal returns (address pairAddress) {
        LSSVMPair pair;

        // Transfer initial NFTs and approve factory
        if (_initialNFTIDs.length > 0) {
            _transferERC721Tokens(_sender, address(this), _nft, _initialNFTIDs);
            IERC721(_nft).setApprovalForAll(address(factory), true);
        }

        // Determine pool type
        LSSVMPair.PoolType poolType = _isBuy
            ? LSSVMPair.PoolType.TOKEN
            : LSSVMPair.PoolType.NFT;

        pair = factory.createPairERC721ETH{value: msg.value}(
            IERC721(_nft),
            _bondingCurve,
            payable(_sender),
            poolType,
            _delta,
            0,
            _spotPrice,
            address(0),
            _initialNFTIDs,
            address(allowListHook),
            address(0)
        );

        // Update pair info and emit event
        _finalizePairCreation(
            _sender,
            pair,
            _initialNFTIDs,
            _lockDuration,
            true
        );

        return address(pair);
    }

    /// @notice Creates an ERC721-ERC20 pair.
    /// @param _sender Address initiating the pair creation.
    /// @param _isBuy Determines if the pair is a buy or sell pool.
    /// @param _nft Address of the ERC721 NFT contract.
    /// @param _bondingCurve Address of the bonding curve contract.
    /// @param _delta Delta parameter for the bonding curve.
    /// @param _spotPrice Initial spot price for the pair.
    /// @param _lockDuration Duration for which the pair is locked.
    /// @param _initialNFTIDs Array of initial ERC721 NFT IDs to add.
    /// @param _initialTokenBalance Initial ERC20 token balance to add.
    /// @param _token Address of the ERC20 token.
    /// @return pairAddress Address of the created pair.
    function _createERC721ERC20Pair(
        address _sender,
        bool _isBuy,
        address _nft,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs,
        uint256 _initialTokenBalance,
        address _token
    ) internal returns (address pairAddress) {
        LSSVMPair pair;

        // Transfer initial NFTs and approve factory
        if (_initialNFTIDs.length > 0) {
            _transferERC721Tokens(_sender, address(this), _nft, _initialNFTIDs);
            IERC721(_nft).setApprovalForAll(address(factory), true);
        }

        // Transfer initial ERC20 tokens and approve factory
        if (_initialTokenBalance > 0) {
            ERC20(_token).safeTransferFrom(
                _sender,
                address(this),
                _initialTokenBalance
            );
            ERC20(_token).safeApprove(address(factory), _initialTokenBalance);
        }

        // Determine pool type
        LSSVMPair.PoolType poolType = _isBuy
            ? LSSVMPair.PoolType.TOKEN
            : LSSVMPair.PoolType.NFT;

        LSSVMPairFactory.CreateERC721ERC20PairParams
            memory params = LSSVMPairFactory.CreateERC721ERC20PairParams({
                token: ERC20(_token),
                nft: IERC721(_nft),
                bondingCurve: _bondingCurve,
                assetRecipient: payable(_sender),
                poolType: poolType,
                delta: _delta,
                fee: 0,
                spotPrice: _spotPrice,
                propertyChecker: address(0),
                initialNFTIDs: _initialNFTIDs,
                initialTokenBalance: _initialTokenBalance,
                hookAddress: address(allowListHook),
                referralAddress: address(0)
            });
        pair = factory.createPairERC721ERC20(params);

        // Update pair info and emit event
        _finalizePairCreation(
            _sender,
            pair,
            _initialNFTIDs,
            _lockDuration,
            true
        );

        return address(pair);
    }

    /// @notice Creates an ERC1155-ETH pair.
    /// @param _sender Address initiating the pair creation.
    /// @param _isBuy Determines if the pair is a buy or sell pool.
    /// @param _nft Address of the ERC1155 NFT contract.
    /// @param _bondingCurve Address of the bonding curve contract.
    /// @param _delta Delta parameter for the bonding curve.
    /// @param _spotPrice Initial spot price for the pair.
    /// @param _lockDuration Duration for which the pair is locked.
    /// @param _nftId Specific ERC1155 NFT ID to add.
    /// @param _initialNFTBalance Initial ERC1155 NFT balance to add for that specific _nftId.
    /// @return pairAddress Address of the created pair.
    function _createERC1155ETHPair(
        address _sender,
        bool _isBuy,
        address _nft,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256 _nftId,
        uint256 _initialNFTBalance
    ) internal returns (address pairAddress) {
        LSSVMPair pair;

        // Transfer initial NFT amount and approve factory
        if (_initialNFTBalance > 0) {
            IERC1155(_nft).safeTransferFrom(
                _sender,
                address(this),
                _nftId,
                _initialNFTBalance,
                bytes("")
            );
            IERC1155(_nft).setApprovalForAll(address(factory), true);
        }

        // Determine pool type
        LSSVMPair.PoolType poolType = _isBuy
            ? LSSVMPair.PoolType.TOKEN
            : LSSVMPair.PoolType.NFT;

        pair = factory.createPairERC1155ETH{value: msg.value}(
            IERC1155(_nft),
            _bondingCurve,
            payable(_sender),
            poolType,
            _delta,
            0,
            _spotPrice,
            _nftId,
            _initialNFTBalance,
            address(allowListHook),
            address(0)
        );

        // Required for params
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = _nftId;

        // Update pair info and emit event
        _finalizePairCreation(_sender, pair, nftIds, _lockDuration, false);

        return address(pair);
    }

    /// @notice Creates an ERC1155-ERC20 pair.
    /// @param _sender Address initiating the pair creation.
    /// @param _isBuy Determines if the pair is a buy or sell pool.
    /// @param _nft Address of the ERC1155 NFT contract.
    /// @param _bondingCurve Address of the bonding curve contract.
    /// @param _delta Delta parameter for the bonding curve.
    /// @param _spotPrice Initial spot price for the pair.
    /// @param _lockDuration Duration for which the pair is locked.
    /// @param _nftId Specific ERC1155 NFT ID to add.
    /// @param _initialNFTBalance Initial ERC1155 NFT balance to add for that specific _nftId.
    /// @param _initialTokenBalance Initial ERC20 token balance to add.
    /// @param _token Address of the ERC20 token.
    /// @return pairAddress Address of the created pair.
    function _createERC1155ERC20Pair(
        address _sender,
        bool _isBuy,
        address _nft,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256 _nftId,
        uint256 _initialNFTBalance,
        uint256 _initialTokenBalance,
        address _token
    ) internal returns (address pairAddress) {
        LSSVMPair pair;

        // Transfer initial NFT amount and approve factory
        if (_initialNFTBalance > 0) {
            IERC1155(_nft).safeTransferFrom(
                _sender,
                address(this),
                _nftId,
                _initialNFTBalance,
                ""
            );
            IERC1155(_nft).setApprovalForAll(address(factory), true);
        }

        // Transfer initial ERC20 tokens and approve factory
        if (_initialTokenBalance > 0) {
            ERC20(_token).safeTransferFrom(
                _sender,
                address(this),
                _initialTokenBalance
            );
            ERC20(_token).safeApprove(address(factory), _initialTokenBalance);
        }

        // Determine pool type
        LSSVMPair.PoolType poolType = _isBuy
            ? LSSVMPair.PoolType.TOKEN
            : LSSVMPair.PoolType.NFT;

        LSSVMPairFactory.CreateERC1155ERC20PairParams
            memory params = LSSVMPairFactory.CreateERC1155ERC20PairParams({
                token: ERC20(_token),
                nft: IERC1155(_nft),
                bondingCurve: _bondingCurve,
                assetRecipient: payable(_sender),
                poolType: poolType,
                delta: _delta,
                fee: 0,
                spotPrice: _spotPrice,
                nftId: _nftId,
                initialNFTBalance: _initialNFTBalance,
                initialTokenBalance: _initialTokenBalance,
                hookAddress: address(allowListHook),
                referralAddress: address(0)
            });
        pair = factory.createPairERC1155ERC20(params);

        // Required for params
        uint256[] memory nftIds = new uint256[](1);
        nftIds[0] = _nftId;

        // Update pair info and emit event
        _finalizePairCreation(_sender, pair, nftIds, _lockDuration, false);

        return address(pair);
    }

    /// @notice Finalizes the pair creation by setting up allow lists and approvals.
    /// @param _sender Address that created the pair.
    /// @param _pair The newly created LSSVMPair.
    /// @param _initialNFTIDs Array of initial NFT IDs added to the pair.
    /// @param _lockDuration Duration for which the pair is locked.
    /// @param _isERC721 Boolean indicating if the pair is for ERC721 NFTs.
    function _finalizePairCreation(
        address _sender,
        LSSVMPair _pair,
        uint256[] memory _initialNFTIDs,
        uint256 _lockDuration,
        bool _isERC721
    ) internal {
        // Set up the allow list for the newly created pair
        allowListHook.modifyAllowListSingleBuyer(_initialNFTIDs, sudoWrapper);

        // Set the address, unlock time, creator, and withdrawal status for the pair
        uint256 unlockTime = block.timestamp + _lockDuration;
        pairInfo[address(_pair)] = PairInfo({
            pairAddress: address(_pair),
            pairUnlockTime: unlockTime,
            pairCreator: _sender,
            hasWithdrawn: false
        });
        pairsByCreator[_sender].push(address(_pair)); // Add the pair to the creator's list of pairs

        // Revoke approvals after pair creation to enhance security
        if (_initialNFTIDs.length > 0) {
            address nft = _pair.nft();
            if (_isERC721) {
                IERC721(nft).setApprovalForAll(address(factory), false);
            } else {
                IERC1155(nft).setApprovalForAll(address(factory), false);
            }
        }

        emit PairCreated(address(_pair), _sender, unlockTime);
    }

    /// @notice Transfers multiple ERC721 tokens from one address to another.
    /// @param _from Address to transfer tokens from.
    /// @param _to Address to transfer tokens to.
    /// @param _nftContract Address of the ERC721 contract.
    /// @param _tokenIDs Array of token IDs to transfer.
    function _transferERC721Tokens(
        address _from,
        address _to,
        address _nftContract,
        uint256[] memory _tokenIDs
    ) internal {
        IERC721 nft = IERC721(_nftContract);
        for (uint256 i = 0; i < _tokenIDs.length; ) {
            nft.safeTransferFrom(_from, _to, _tokenIDs[i]);

            // Gas savings
            unchecked {
                ++i;
            }
        }
    }
}
