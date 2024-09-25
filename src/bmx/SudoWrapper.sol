// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {LSSVMPairFactory} from "../LSSVMPairFactory.sol";
import {LSSVMPair} from "../LSSVMPair.sol";
import {ILSSVMPair} from "../ILSSVMPair.sol";
import {ILSSVMPairFactoryLike} from "../ILSSVMPairFactoryLike.sol";
import {VRFConsumer} from "./VRFConsumer.sol";

contract SudoVRFWrapper is
    Ownable,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder
{
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    uint256 public constant MAX_FEE = 5e16; // 5%

    VRFConsumer public vrfConsumer;
    uint256[] public allRequestIds;
    uint256 public allRequestIdsLength;
    uint256 public fee;
    address public feeRecipient;

    struct BuyRequest {
        bool completed;
        address user;
        address pair;
        uint256 nftAmount;
        uint256 inputAmount;
        uint256[] totalPairAssets;
        uint256[] result;
    }

    mapping(address => uint256[]) private userToRequestIds; // user => requestIds
    mapping(uint256 => address) private requestIdToUser; // requestId => user
    mapping(uint256 => BuyRequest) private buyRequests; // requestId => BuyRequest

    event NFTsBought(
        address indexed pair,
        address indexed buyer,
        uint256[] nftIds
    );
    event NFTsSold(
        address indexed pair,
        address indexed seller,
        uint256[] nftIds,
        uint256 outputAmount
    );
    event FeeConfigUpdated(uint256 fee, address feeRecipient);

    constructor(address _vrfConsumer, uint256 _fee, address _feeRecipient) {
        require(
            _vrfConsumer != address(0) && _feeRecipient != address(0),
            "Invalid addresses"
        );
        require(_fee <= MAX_FEE, "Wrapper fee must be less than 5%");

        vrfConsumer = VRFConsumer(_vrfConsumer);
        fee = _fee;
        feeRecipient = _feeRecipient;
    }

    // Function to receive ETH
    receive() external payable {}

    modifier onlyVRFConsumer() {
        require(
            msg.sender == address(vrfConsumer),
            "Only the VRFConsumer can call this function"
        );
        _;
    }

    function _buyNFTs(
        // msg.sender is wrong (VRF will call this)
        address _pair,
        uint256[] calldata _nftIds,
        uint256 _maxExpectedTokenInput
    ) internal {
        LSSVMPair pair = LSSVMPair(_pair);
        bool isETHPair = pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH;
        bool isERC721Pair = pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20;

        // Perform the swap through the pair
        uint256 amountUsed = pair.swapTokenForSpecificNFTs{
            value: isETHPair ? inputAmount : 0
        }(_nftIds, inputAmount, address(this), false, address(this));

        // Transfer the NFTs to the buyer
        if (
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20
        ) {
            IERC721 nft = IERC721(pair.nft());
            for (uint256 i = 0; i < _nftIds.length; i++) {
                nft.safeTransferFrom(address(this), msg.sender, _nftIds[i]);

                unchecked {
                    ++i;
                }
            }
        } else {
            IERC1155(pair.nft()).safeTransferFrom(
                address(this),
                msg.sender,
                LSSVMPairERC1155(_pair).nftId(),
                _nftIds[0],
                bytes("")
            );
        }

        // Refund any excess ETH or ERC20 tokens
        if (amountUsed < inputAmount) {
            if (isETHPair) {
                payable(msg.sender).safeTransferETH(inputAmount - amountUsed);
            } else {
                ILSSVMPair(_pair).token().safeTransfer(
                    msg.sender,
                    inputAmount - amountUsed
                );
            }
        }

        emit NFTsBought(_pair, msg.sender, _nftIds);
    }

    function buyNFTsCallback(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) external nonReentrant onlyVRFConsumer {
        BuyRequest request = buyRequests[_requestId];
        uint256[] memory randomResults = new uint256[](request.nftAmount);
        bool isERC721Pair = request.pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
                            request.pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20;

        if (isERC721Pair) {
            for (uint256 i = 0; i < request.nftAmount; i++) {
                uint256 randomIndex = _randomWords[i] % request.totalPairAssets.length;
                randomResults[i] = request.totalPairAssets[randomIndex];
            }
        } else {
            // ERC1155 case
            uint256 totalAmount = IERC1155(request.pair.nft()).balanceOf(address(request.pair), request.totalPairAssets[0]);
            for (uint256 i = 0; i < request.nftAmount; i++) {
                uint256 randomAmount = (_randomWords[i] % totalAmount) + 1; // Ensure non-zero amount
                randomResults[i] = randomAmount;
            }
        }
        request.result = randomResults;
        request.completed = true;
    }

    // User calls this function to request randomness from VRF, which needs to get user ETH or ERC20 tokens, approve the pair, and map the requestId to the inputted params
    function buyNFTs(
        address _pair,
        uint256 _nftAmount,
        uint256 _maxExpectedTokenInput
    ) external payable nonReentrant returns (uint256 requestId) {
        require(_pair != address(0), "Invalid pair");
        require(
            _nftAmount > 0 && _maxExpectedTokenInput > 0,
            "Invalid amounts"
        );

        LSSVMPair pair = LSSVMPair(_pair);
        bool isETHPair = pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH;
        bool isERC721Pair = pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20;
        uint256[] memory totalPairAssets; // All ERC721 token IDs or ERC1155 amount for token ID

        if (isERC721Pair) {
            totalPairAssets = LSSVMPairERC721(_pair).getAllIds();
            require(
                _nftAmount < totalPairAssets.length,
                "Not enough NFTs"
            );
        } else {
            totalPairAssets = new uint256[](1);
            totalPairAssets[0] = LSSVMPairERC1155(_pair).nftId();
            require(
                _nftAmount < IERC1155(pair.nft()).balanceOf(msg.sender, totalPairAssets[0]),
                "Not enough NFTs"
            );
        }

        uint256 inputAmount = isETHPair ? msg.value : _maxExpectedTokenInput;

        if (!isETHPair) {
            // For ERC20 pairs, transfer tokens from the buyer to this contract
            ERC20 token = ILSSVMPair(_pair).token();
            (, , , uint256 price, , ) = pair.getBuyNFTQuote(0, _nftAmount);
            token.safeTransferFrom(msg.sender, address(this), price);
            token.safeApprove(_pair, price);
        }

        requestId = vrfConsumer.requestRandomWords();
        buyRequests[requestId] = BuyRequest({
            completed: false,
            user: msg.sender,
            pair: _pair,
            nftAmount: _nftAmount,
            inputAmount: inputAmount,
            totalPairAssets: totalPairAssets,
            result: new uint256[](0)
        });
        userToRequestIds[msg.sender].push(requestId);
        requestIdToUser[requestId] = msg.sender;
    }

    function sellNFTs(
        address _pair,
        uint256[] calldata _nftIds,
        uint256 _minExpectedTokenOutput
    ) external nonReentrant returns (uint256 outputAmount) {
        require(_pair != address(0), "Invalid pair");
        require(
            _nftIds.length > 0 && _minExpectedTokenOutput > 0,
            "Invalid input"
        );

        LSSVMPair pair = LSSVMPair(_pair);
        address nftAddress = pair.nft();

        if (
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC721_ERC20
        ) {
            IERC721 nft = IERC721(nftAddress);
            // Transfer NFTs from the seller to this contract
            for (uint256 i = 0; i < _nftIds.length; i++) {
                nft.safeTransferFrom(msg.sender, address(this), _nftIds[i]);

                unchecked {
                    ++i;
                }
            }
            nft.setApprovalForAll(_pair, true);
        } else {
            IERC1155 nft = IERC1155(nftAddress);
            nft.safeTransferFrom(
                msg.sender,
                address(this),
                LSSVMPairERC1155(_pair).nftId(),
                _nftIds[0],
                bytes("")
            );
            nft.setApprovalForAll(_pair, true);
        }

        // Perform the swap through the pair and transfer tokens to the seller
        uint256 amountBeforeWrapperFee = pair.swapNFTsForToken(
            _nftIds,
            _minExpectedTokenOutput,
            payable(address(this)),
            false,
            address(this)
        );

        // Calculate the final output and wrapper fee based on the amount before fees and royalty
        (
            ,
            ,
            ,
            uint256 totalAmount,
            uint256 sudoswapFee,
            uint256 royaltyAmount
        ) = pair.getSellNFTQuote(_nftIds[0], _nftIds.length);
        uint256 wrapperFee = (totalAmount + sudoswapFee + royaltyAmount)
            .mulWadUp(fee);
        outputAmount = amountBeforeWrapperFee - wrapperFee;

        // Transfer the wrapper fee to fee recipient and the rest to the user
        if (
            pair.pairVariant() ==
            ILSSVMPairFactoryLike.PairVariant.ERC721_ETH ||
            pair.pairVariant() == ILSSVMPairFactoryLike.PairVariant.ERC1155_ETH
        ) {
            payable(feeRecipient).safeTransferETH(wrapperFee);
            payable(msg.sender).safeTransferETH(outputAmount);
        } else {
            ERC20 token = ILSSVMPair(_pair).token();
            token.safeTransfer(feeRecipient, wrapperFee);
            token.safeTransfer(msg.sender, outputAmount);
        }

        emit NFTsSold(_pair, msg.sender, _nftIds, outputAmount);
    }

    /// @notice Updates the fee and fee recipient for the wrapper contract.
    /// @param _newFee The new fee to be set.
    /// @param _newFeeRecipient The new fee recipient to be set.
    function updateFeeConfig(
        uint256 _newFee,
        address _newFeeRecipient
    ) external onlyOwner {
        require(_newFee <= MAX_FEE, "Additional fee must be less than 5%");
        require(_newFeeRecipient != address(0), "Invalid address");

        fee = _newFee;
        feeRecipient = _newFeeRecipient;
        emit FeeConfigUpdated(_newFee, _newFeeRecipient);
    }
}
