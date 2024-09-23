// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../LSSVMPairFactory.sol";
import "../LSSVMPair.sol";
import "../hooks/AllowListHook.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "../ILSSVMPairFactoryLike.sol";
import "./VRFConsumer.sol";

contract SudoSwapWrapper is Ownable {
    uint256 public constant MINIMUM_LOCK_DURATION = 24 hours;
    uint96 public constant MAX_FEE = 5000;
    
    LSSVMPairFactory public immutable factory;
    VRFConsumer public immutable vrfConsumer;
    AllowListHook public allowListHook;

    uint256[] public allRequestIds;
    uint256 public allRequestIdsLength;
    uint96 public fee;

    struct BuyOrSell {
        bool exists;
        bool completed;
        bool isBuy;
        address user;
        address pair;
        uint256 nftAmount;
        uint256[] result;
    }

    mapping(address => uint256) public pairUnlockTimes;
    mapping(address => address) public pairCreators;
    mapping(uint256 => BuyOrSell) public buyOrSellRequests;

    event PoolCreated(address indexed pair, address indexed creator, uint256 unlockTime);
    event NFTsBought(address indexed pair, address indexed buyer, uint256[] nftIds);
    event NFTsSold(address indexed pair, address indexed seller, uint256[] nftIds);
    event NFTsWithdrawn(address indexed pair, address indexed withdrawer, uint256[] nftIds);
    event TokensWithdrawn(address indexed pair, address indexed withdrawer, uint256 amount);
    event AllowListHookUpdated(address newAllowListHook);
    event FeeUpdated(uint96 newFee);

    constructor(address _factory, address _vrfConsumer, address _allowListHook, uint96 _fee) {
        require(_factory != address(0) && _vrfConsumer != address(0) && _allowListHook != address(0), "Invalid addresses");
        require(_fee < MAX_FEE, "Additional fee must be less than 5000");

        factory = LSSVMPairFactory(_factory);
        vrfConsumer = VRFConsumer(_vrfConsumer);
        allowListHook = AllowListHook(_allowListHook);
        fee = _fee;
    }

    // Function to receive ETH
    receive() external payable {}

    modifier onlyVRFConsumer() {
        require(msg.sender == address(vrfConsumer), "Only the VRFConsumer can call this function");
        _;
    }

    function createBuyPool(
        address _nft,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs,
        bool isERC721,
        bool isETH,
        address _token,
        uint256 _nftId
    ) external payable {
        require(_lockDuration >= MINIMUM_LOCK_DURATION, "Lock duration must be at least 24 hours");

        LSSVMPair pair;
        if (isERC721 && isETH) {
            pair = factory.createPairERC721ETH{value: msg.value}(
                IERC721(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.TOKEN,
                _delta,
                fee,
                _spotPrice,
                address(0),
                _initialNFTIDs,
                address(allowListHook),
                address(0)
            );
        } else if (isERC721 && !isETH) {
            pair = factory.createPairERC721ERC20(
                ERC20(_token),
                IERC721(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.TOKEN,
                _delta,
                fee,
                _spotPrice,
                address(0),
                _initialNFTIDs,
                msg.value,
                address(allowListHook),
                address(0)
            );
        } else if (!isERC721 && isETH) {
            pair = factory.createPairERC1155ETH{value: msg.value}(
                IERC1155(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.TOKEN,
                _delta,
                fee,
                _spotPrice,
                _nftId,
                _initialNFTIDs.length > 0 ? _initialNFTIDs[0] : 0,
                address(allowListHook),
                address(0)
            );
        } else if (!isERC721 && !isETH) {
            pair = factory.createPairERC1155ERC20(
                ERC20(_token),
                IERC1155(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.TOKEN,
                _delta,
                fee,
                _spotPrice,
                _nftId,
                _initialNFTIDs.length > 0 ? _initialNFTIDs[0] : 0,
                msg.value,
                address(allowListHook),
                address(0)
            );
        } else {
            revert("Unsupported pool type");
        }

        // Set up the allow list for the newly created pair
        address[] memory allowedAddresses = new address[](1);
        allowedAddresses[0] = address(this);
        allowListHook.modifyAllowList(_initialNFTIDs, allowedAddresses);

        // Set the unlock time and creator for the pair
        uint256 unlockTime = block.timestamp + _lockDuration;
        pairUnlockTimes[address(pair)] = unlockTime;
        pairCreators[address(pair)] = msg.sender;

        emit PoolCreated(address(pair), msg.sender, unlockTime);
    }

    function createSellPool(
        address _nft,
        ICurve _bondingCurve,
        uint128 _delta,
        uint128 _spotPrice,
        uint256 _lockDuration,
        uint256[] calldata _initialNFTIDs,
        bool isERC721,
        bool isETH,
        address _token,
        uint256 _nftId
    ) external {
        require(_lockDuration >= MINIMUM_LOCK_DURATION, "Lock duration must be at least 24 hours");

        LSSVMPair pair;
        if (isERC721 && isETH) {
            IERC721(_nft).setApprovalForAll(address(factory), true);
            pair = factory.createPairERC721ETH(
                IERC721(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.NFT,
                _delta,
                fee,
                _spotPrice,
                address(0),
                _initialNFTIDs,
                address(allowListHook),
                address(0)
            );
        } else if (isERC721 && !isETH) {
            IERC721(_nft).setApprovalForAll(address(factory), true);
            pair = factory.createPairERC721ERC20(
                ERC20(_token),
                IERC721(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.NFT,
                _delta,
                fee,
                _spotPrice,
                address(0),
                _initialNFTIDs,
                0,
                address(allowListHook),
                address(0)
            );
        } else if (!isERC721 && isETH) {
            IERC1155(_nft).setApprovalForAll(address(factory), true);
            pair = factory.createPairERC1155ETH(
                IERC1155(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.NFT,
                _delta,
                fee,
                _spotPrice,
                _nftId,
                _initialNFTIDs.length > 0 ? _initialNFTIDs[0] : 0,
                address(allowListHook),
                address(0)
            );
        } else if (!isERC721 && !isETH) {
            IERC1155(_nft).setApprovalForAll(address(factory), true);
            pair = factory.createPairERC1155ERC20(
                ERC20(_token),
                IERC1155(_nft),
                _bondingCurve,
                payable(address(this)),
                LSSVMPair.PoolType.NFT,
                _delta,
                fee,
                _spotPrice,
                _nftId,
                _initialNFTIDs.length > 0 ? _initialNFTIDs[0] : 0,
                0,
                address(allowListHook),
                address(0)
            );
        } else {
            revert("Unsupported pool type");
        }

        // Set up the allow list for the newly created pair
        address[] memory allowedAddresses = new address[](1);
        allowedAddresses[0] = address(this);
        allowListHook.modifyAllowList(_initialNFTIDs, allowedAddresses);

        // Set the unlock time and creator for the pair
        uint256 unlockTime = block.timestamp + _lockDuration;
        pairUnlockTimes[address(pair)] = unlockTime;
        pairCreators[address(pair)] = msg.sender;

        emit PoolCreated(address(pair), msg.sender, unlockTime);
    }

    function _buyNFTs(address _pair, uint256[] calldata _nftIds) internal payable {
        LSSVMPair pair = LSSVMPair(_pair);
        uint256 inputAmount = msg.value;
        bool isETHPair = pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
                         pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH;
        
        if (!isETHPair) {
            // For ERC20 pairs, transfer tokens from the buyer to this contract
            IERC20 token = IERC20(pair.token());
            uint256 price = pair.getBuyNFTQuote(_nftIds.length);
            token.transferFrom(msg.sender, address(this), price);
            token.approve(_pair, price);
            inputAmount = price;
        }

        // Perform the swap through the pair
        uint256 remainingValue = pair.swapTokenForSpecificNFTs{value: isETHPair ? inputAmount : 0}(
            _nftIds,
            inputAmount,
            address(this),
            false,
            address(this)
        );

        // Transfer the NFTs to the buyer
        if (pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH || 
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20) {
            IERC721 nft = IERC721(pair.nft());
            for (uint256 i = 0; i < _nftIds.length; i++) {
                nft.transferFrom(address(this), msg.sender, _nftIds[i]);
            }
        } else {
            IERC1155 nft = IERC1155(pair.nft());
            nft.safeTransferFrom(address(this), msg.sender, pair.nftId(), _nftIds[0], "");
        }

        // Refund any excess ETH or ERC20 tokens
        if (remainingValue > 0) {
            if (isETHPair) {
                payable(msg.sender).transfer(remainingValue);
            } else {
                IERC20(pair.token()).transfer(msg.sender, remainingValue);
            }
        }

        emit NFTsBought(_pair, msg.sender, _nftIds);
    }

    function _sellNFTs(address _pair, uint256[] calldata _nftIds) internal {
        LSSVMPair pair = LSSVMPair(_pair);

        if (pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH || 
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20) {
            IERC721 nft = IERC721(pair.nft());

            // Transfer NFTs from the seller to this contract
            for (uint256 i = 0; i < _nftIds.length; i++) {
                nft.transferFrom(msg.sender, address(this), _nftIds[i]);
                nft.approve(_pair, _nftIds[i]);
            }
        } else {
            IERC1155 nft = IERC1155(pair.nft());
            nft.safeTransferFrom(msg.sender, address(this), pair.nftId(), _nftIds[0], "");
            nft.setApprovalForAll(_pair, true);
        }

        // Perform the swap through the pair
        uint256 outputAmount = pair.swapNFTsForToken(_nftIds, 0, payable(address(this)), false, address(this));

        // Transfer the tokens to the seller
        if (pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH || 
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH) {
            payable(msg.sender).transfer(outputAmount);
        } else {
            IERC20(pair.token()).transfer(msg.sender, outputAmount);
        }

        emit NFTsSold(_pair, msg.sender, _nftIds);
    }

    function buyOrSellCallback(uint256 _requestId, uint256[] calldata _randomWords) external onlyVRFConsumer {
        
    }

    // User calls this function to request randomness from VRF, which needs to map the requestId to the inputted params
    function buyOrSellNFTs(address _pair, uint256 _nftAmount, bool _isBuy) external payable returns (uint256) {
        
    }

    function withdrawNFTs(address _pair, uint256[] calldata _nftIds) external {
        require(msg.sender == pairCreators[_pair], "Only the creator can withdraw");
        require(block.timestamp >= pairUnlockTimes[_pair], "Pool is still locked");

        LSSVMPair pair = LSSVMPair(_pair);

        if (pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH || 
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20) {
            pair.withdrawERC721(_nftIds);
            IERC721 nft = IERC721(pair.nft());
            for (uint256 i = 0; i < _nftIds.length; i++) {
                nft.transferFrom(address(this), msg.sender, _nftIds[i]);
            }
        } else {
            pair.withdrawERC1155(_nftIds[0]);
            IERC1155 nft = IERC1155(pair.nft());
            nft.safeTransferFrom(address(this), msg.sender, pair.nftId(), _nftIds[0], "");
        }

        emit NFTsWithdrawn(_pair, msg.sender, _nftIds);
    }

    function withdrawTokens(address _pair, uint256 _amount) external {
        require(msg.sender == pairCreators[_pair], "Only the creator can withdraw");
        require(block.timestamp >= pairUnlockTimes[_pair], "Pool is still locked");

        LSSVMPair pair = LSSVMPair(_pair);

        if (pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH || 
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH) {
            LSSVMPairETH(payable(_pair)).withdrawAllETH();
            payable(msg.sender).transfer(_amount);
        } else {
            pair.withdrawERC20(_amount);
            IERC20(pair.token()).transfer(msg.sender, _amount);
        }

        emit TokensWithdrawn(_pair, msg.sender, _amount);
    }

    function getRemainingLockTime(address _pair) external view returns (uint256) {
        uint256 unlockTime = pairUnlockTimes[_pair];
        if (unlockTime <= block.timestamp) {
            return 0;
        }
        return unlockTime - block.timestamp;
    }

    function setAllowListHook(address _newAllowListHook) external onlyOwner {
        allowListHook = AllowListHook(_newAllowListHook);
        emit AllowListHookUpdated(_newAllowListHook);
    }

    function setFee(uint96 _newFee) external onlyOwner {
        fee = _newFee;
        emit FeeUpdated(_newFee);
    }
}