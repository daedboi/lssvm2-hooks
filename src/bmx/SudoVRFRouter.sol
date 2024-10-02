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

import {ILSSVMPairFactory, ILSSVMPair, IVRFConsumer, ISudoFactoryWrapper, IAllowListHook} from "./Interfaces.sol";

/**
 * @title SudoVRFRouter
 * @author 0xdaedboi
 * @notice This contract is used as a router for buying and selling SudoSwap pairs with Chainlink randomness enabled for buying NFTs.
 */
contract SudoVRFRouter is
    Ownable,
    ReentrancyGuard,
    ERC721Holder,
    ERC1155Holder
{
    using SafeTransferLib for address payable;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    // =========================================
    // Constants and Immutable Variables
    // =========================================

    /// @notice The maximum fee percentage (5%)
    uint256 public constant MAX_FEE = 5e16;

    /// @notice The delay before a request can be cancelled
    uint256 public constant CANCELLATION_DELAY = 5 minutes;

    /// @notice SudoFactoryWrapper contract instance
    ISudoFactoryWrapper public immutable factoryWrapper;

    // =========================================
    // State Variables
    // =========================================

    /// @notice VRFConsumer contract instance
    IVRFConsumer public vrfConsumer;

    /// @notice AllowListHook contract instance
    IAllowListHook public allowListHook;

    /// @notice The current fee percentage
    uint256 public fee;

    /// @notice The fee recipient address
    address public feeRecipient;

    /// @notice Mapping from user address to their request IDs
    mapping(address => uint256[]) private userToRequestIds;

    /// @notice Mapping from request ID to BuyRequest
    mapping(uint256 => BuyRequest) private buyRequests;

    // =========================================
    // Structs
    // =========================================

    /// @notice Struct representing a buy request for random NFTs
    struct BuyRequest {
        bool fulfilled;
        bool claimed;
        bool cancelled;
        address user;
        address pair;
        uint256 nftAmount;
        uint256 inputAmount;
        uint256[] randomResult;
        uint256[] claimedTokenIds;
        uint256 timestamp;
    }

    /// @notice Struct representing a buy request for random NFTs (public)
    struct BuyRequestPublic {
        bool fulfilled;
        bool claimed;
        bool cancelled;
        address user;
        address pair;
        uint256 nftAmount;
        uint256 inputAmount;
        uint256[] claimedTokenIds;
        uint256 timestamp;
    }

    // =========================================
    // Events
    // =========================================

    event NFTsBought(
        address indexed pair,
        address indexed buyer,
        uint256[] nftIds,
        uint256 finalPrice
    );
    event NFTsSold(
        address indexed pair,
        address indexed seller,
        uint256[] nftIds,
        uint256 outputAmount
    );
    event FeeTransferred(
        address indexed recipient,
        uint256 amount,
        address indexed pair
    );
    event FeeConfigUpdated(uint256 fee, address feeRecipient);
    event RequestFulfilled(address indexed user, uint256 requestId);
    event VRFConsumerUpdated(address newVRFConsumer);
    event AllowListHookUpdated(address newAllowListHook);
    event RequestCancelled(address indexed user, uint256 requestId);
    event Refunded(address indexed to, uint256 amount, address indexed pair);

    // =========================================
    // Constructor
    // =========================================

    /**
     * @notice Initializes the contract with the given parameters.
     * @param _vrfConsumer The address of the VRFConsumer contract.
     * @param _fee The initial fee percentage.
     * @param _feeRecipient The address of the fee recipient.
     * @param _factoryWrapper The address of the SudoFactoryWrapper contract.
     */
    constructor(
        address _vrfConsumer,
        uint256 _fee,
        address _feeRecipient,
        address payable _factoryWrapper
    ) {
        require(
            _vrfConsumer != address(0) &&
                _feeRecipient != address(0) &&
                _factoryWrapper != address(0),
            "Invalid addresses"
        );
        require(_fee <= MAX_FEE, "Wrapper fee cannot be greater than 5%");

        vrfConsumer = IVRFConsumer(_vrfConsumer);
        fee = _fee;
        feeRecipient = _feeRecipient;
        factoryWrapper = ISudoFactoryWrapper(_factoryWrapper);
    }

    /**
     * @notice Receive function to accept ETH.
     */
    receive() external payable {}

    // =========================================
    // Modifiers
    // =========================================

    /**
     * @notice Modifier to ensure only the VRFConsumer can call the function.
     */
    modifier onlyVRFConsumer() {
        require(
            msg.sender == address(vrfConsumer),
            "Only the VRFConsumer can call this function"
        );
        _;
    }

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Claims the random NFTs after the VRF request is fulfilled.
     * @return nftIds The IDs of the NFTs claimed.
     */
    function claimRandomNFTs()
        external
        nonReentrant
        returns (uint256[] memory nftIds)
    {
        // Check if the user has any pending buy requests
        uint256[] storage userRequests = userToRequestIds[msg.sender];
        require(userRequests.length > 0, "User has no pending buy requests");

        // Get the last request
        BuyRequest storage request = buyRequests[
            userRequests[userRequests.length - 1]
        ];

        // Ensure the request is fulfilled and not already claimed or cancelled
        require(request.fulfilled, "Last request is not fulfilled");
        require(
            !request.claimed && !request.cancelled,
            "Last request has already been claimed or cancelled"
        );

        ILSSVMPair pair = ILSSVMPair(request.pair);
        bool isETHPair = _isETHPair(pair);
        uint256[] memory allPairNFTIds = pair.getAllIds();

        if (
            request.nftAmount > allPairNFTIds.length ||
            request.randomResult.length < request.nftAmount
        ) {
            // Not enough NFTs or random results; refund the user
            request.cancelled = true;
            _refundUser(msg.sender, request.inputAmount, pair);
            return new uint256[](0);
        }

        (uint256 finalPrice, uint256 wrapperFee, ) = calculateBuyOrSell(
            request.pair,
            request.nftAmount,
            0, // Asset ID is 0 for ERC721
            true // It's a buy operation
        );

        if (request.inputAmount < finalPrice) {
            // Insufficient funds; refund the user
            request.cancelled = true;
            _refundUser(msg.sender, request.inputAmount, pair);
            return new uint256[](0);
        }

        // Get random NFT IDs from allPairNFTIds using request.randomResult
        uint256[] memory randomNFTIds = new uint256[](request.nftAmount);
        for (uint256 i = 0; i < request.nftAmount; ) {
            uint256 randomIndex = request.randomResult[i] %
                allPairNFTIds.length;
            randomNFTIds[i] = allPairNFTIds[randomIndex];

            unchecked {
                ++i;
            }
        }

        // request.inputAmount is finalPrice + slippage so we deduct the finalPrice from it
        uint256 swapAmount = (finalPrice - wrapperFee) +
            (request.inputAmount - finalPrice);
        uint256 amountUsed;

        // Perform the swap through the pair
        request.claimed = true;
        try
            pair.swapTokenForSpecificNFTs{value: isETHPair ? swapAmount : 0}(
                randomNFTIds,
                swapAmount,
                address(this),
                false,
                address(this)
            )
        returns (uint256 _amountUsed) {
            amountUsed = _amountUsed;
            _transferNFTs(address(this), msg.sender, pair, randomNFTIds, false);
        } catch {
            // Reset claimed state
            request.claimed = false;
            request.cancelled = true;
            _refundUser(msg.sender, request.inputAmount, pair);
            return new uint256[](0);
        }

        // Transfer fee to fee recipient
        _transferFee(wrapperFee, pair);

        if (amountUsed < swapAmount) {
            _refundUser(msg.sender, swapAmount - amountUsed, pair);
        }

        request.claimedTokenIds = randomNFTIds;

        emit NFTsBought(request.pair, msg.sender, randomNFTIds, finalPrice);

        return randomNFTIds;
    }

    /**
     * @notice Callback function called by the VRFConsumer to deliver randomness.
     * @param _requestId The VRF request ID.
     * @param _randomWords The random numbers provided by VRF.
     */
    function buyNFTsCallback(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) external nonReentrant onlyVRFConsumer {
        BuyRequest storage request = buyRequests[_requestId];
        request.randomResult = _randomWords;
        request.fulfilled = true;

        emit RequestFulfilled(request.user, _requestId);
    }

    /**
     * @notice Allows a user to cancel an unfulfilled VRF request and retrieve their funds.
     * @param requestId The ID of the VRF request to cancel.
     */
    function cancelUnfulfilledRequest(uint256 requestId) external nonReentrant {
        BuyRequest storage request = buyRequests[requestId];
        require(request.user == msg.sender, "Not your request");
        require(
            !request.fulfilled && !request.cancelled,
            "Request already fulfilled or cancelled"
        );
        require(
            block.timestamp >= request.timestamp + CANCELLATION_DELAY,
            "Wait before cancelling"
        );

        request.cancelled = true;

        // Refund the user
        _refundUser(msg.sender, request.inputAmount, ILSSVMPair(request.pair));

        emit RequestCancelled(msg.sender, requestId);
    }

    /**
     * @notice Buys random NFTs from a sell pool using Chainlink VRF randomness.
     * @param _pair The address of the pair to buy from.
     * @param _nftAmount The number of NFTs to buy.
     * @param _maxExpectedTokenInput The maximum token input expected (including fees and slippage).
     * @return requestId The ID of the VRF request.
     */
    function buyRandomNFTs(
        address _pair,
        uint256 _nftAmount,
        uint256 _maxExpectedTokenInput
    ) external payable nonReentrant returns (uint256 requestId) {
        require(
            factoryWrapper.isRandomPair(_pair),
            "Pair is not a random pair"
        );
        require(
            _nftAmount > 0 && _maxExpectedTokenInput > 0,
            "Invalid amounts"
        );
        require(
            block.timestamp < factoryWrapper.getUnlockTime(_pair),
            "Can only buy before pair is unlocked"
        );

        // Ensure the user doesn't have an unclaimed request
        uint256[] memory userRequests = userToRequestIds[msg.sender];
        if (userRequests.length > 0) {
            uint256 lastRequestId = userRequests[userRequests.length - 1];
            require(
                buyRequests[lastRequestId].claimed ||
                    buyRequests[lastRequestId].cancelled,
                "User has a pending buy request and hasn't claimed or cancelled yet"
            );
        }

        ILSSVMPair pair = ILSSVMPair(_pair);
        require(_nftAmount <= pair.getAllIds().length, "Not enough NFTs");

        (uint256 finalPrice, , ) = calculateBuyOrSell(
            _pair,
            _nftAmount,
            0, // Asset ID is 0 for ERC721
            true // It's a buy operation
        );
        uint256 inputAmount = _isETHPair(pair)
            ? msg.value
            : _maxExpectedTokenInput;
        require(inputAmount >= finalPrice, "Insufficient funds to buy NFTs");

        if (!_isETHPair(pair)) {
            // For ERC20 pairs, transfer tokens from the buyer to this contract and approve the pair
            ERC20 token = pair.token();
            token.safeTransferFrom(msg.sender, address(this), inputAmount);
            token.safeApprove(_pair, inputAmount);
        }

        requestId = vrfConsumer.requestRandomWords(uint32(_nftAmount));
        buyRequests[requestId] = BuyRequest({
            fulfilled: false,
            claimed: false,
            cancelled: false,
            user: msg.sender,
            pair: _pair,
            nftAmount: _nftAmount,
            inputAmount: inputAmount,
            randomResult: new uint256[](0),
            claimedTokenIds: new uint256[](0),
            timestamp: block.timestamp
        });
        userToRequestIds[msg.sender].push(requestId);
    }

    /**
     * @notice Sells NFTs to a pair.
     * @param _pair The address of the pair to sell to.
     * @param _nftIds The IDs of the NFTs to sell for ERC721 or the amount for ERC1155.
     * @param _minExpectedTokenOutput The minimum expected token output.
     * @return outputAmount The amount of tokens received after sale.
     */
    function sellNFTs(
        address _pair,
        uint256[] calldata _nftIds,
        uint256 _minExpectedTokenOutput
    ) external nonReentrant returns (uint256 outputAmount) {
        require(_pair != address(0), "Invalid pair");
        require(
            factoryWrapper.isPair(_pair) && !factoryWrapper.isRandomPair(_pair),
            "Must be a valid non-random pair"
        );
        require(
            _nftIds.length > 0 && _minExpectedTokenOutput > 0,
            "Invalid input"
        );
        require(
            block.timestamp < factoryWrapper.getUnlockTime(_pair),
            "Can only sell before pair is unlocked"
        );

        ILSSVMPair pair = ILSSVMPair(_pair);
        require(
            pair.poolType() == ILSSVMPair.PoolType.TOKEN,
            "Pair is not a buy pool"
        );

        // Transfer NFTs from the seller to this contract and approve the pair
        _transferNFTs(msg.sender, address(this), pair, _nftIds, true);

        // Set the allow list for the NFTs being sold
        allowListHook.modifyAllowListSingleBuyer(_nftIds, address(this));

        // Perform the swap through the pair and transfer tokens to the seller
        uint256 amountBeforeWrapperFee = pair.swapNFTsForToken(
            _nftIds,
            _minExpectedTokenOutput,
            payable(address(this)),
            false,
            address(this)
        );

        // Calculate the  wrapper fee
        (, uint256 wrapperFee, ) = calculateBuyOrSell(
            _pair,
            _nftIds.length,
            _nftIds[0],
            false
        );
        outputAmount = amountBeforeWrapperFee - wrapperFee;

        // Transfer the wrapper fee to fee recipient and the rest to the user
        _transferFee(wrapperFee, pair);
        _transferTokens(msg.sender, outputAmount, pair);

        // Transfer the sold NFTs to the pair creator
        _transferNFTs(
            address(this),
            factoryWrapper.getPairCreator(_pair),
            pair,
            _nftIds,
            false
        );

        emit NFTsSold(_pair, msg.sender, _nftIds, outputAmount);
    }

    // =========================================
    // View Functions
    // =========================================

    /**
     * @notice Calculates the final price, wrapper fee, and royalty amount for buying or selling NFTs.
     * @param _pair The address of the pair.
     * @param _nftAmount The number of NFTs to buy or sell.
     * @param _assetId The ID of the asset (only needed for selling ERC1155, set to 0 for ERC721).
     * @param _isBuy True if the operation is a buy, false if it's a sell.
     * @return finalPrice The final price the user has to pay or receive.
     * @return wrapperFee The wrapper fee associated with the transaction.
     * @return royaltyAmount The royalty amount associated with the transaction.
     */
    function calculateBuyOrSell(
        address _pair,
        uint256 _nftAmount,
        uint256 _assetId,
        bool _isBuy
    )
        public
        view
        returns (uint256 finalPrice, uint256 wrapperFee, uint256 royaltyAmount)
    {
        ILSSVMPair pair = ILSSVMPair(_pair);

        if (_isBuy) {
            (
                ,
                ,
                ,
                uint256 priceWithoutWrapperFee,
                uint256 _sudoswapFee,
                uint256 _royaltyAmount
            ) = pair.getBuyNFTQuote(0, _nftAmount);

            uint256 amountExcludingFees = priceWithoutWrapperFee -
                _sudoswapFee -
                _royaltyAmount;
            wrapperFee = amountExcludingFees.mulWadUp(fee);
            finalPrice = priceWithoutWrapperFee + wrapperFee;
            royaltyAmount = _royaltyAmount;
        } else {
            (
                ,
                ,
                ,
                uint256 totalAmountReceived,
                uint256 _sudoswapFee,
                uint256 _royaltyAmount
            ) = pair.getSellNFTQuote(_assetId, _nftAmount);

            uint256 amountExcludingFees = totalAmountReceived +
                _sudoswapFee +
                _royaltyAmount;
            wrapperFee = amountExcludingFees.mulWadUp(fee);
            finalPrice = totalAmountReceived - wrapperFee;
            royaltyAmount = _royaltyAmount;
        }
    }

    /**
     * @notice Returns all buy requests for a given user.
     * @dev We exclude the random results from the public view.
     * @param user The address of the user.
     * @return requests An array of BuyRequest structs.
     */
    function getBuyRequests(
        address user
    ) external view returns (BuyRequestPublic[] memory requests) {
        uint256[] storage userRequests = userToRequestIds[user];
        requests = new BuyRequestPublic[](userRequests.length);
        for (uint256 i = 0; i < userRequests.length; i++) {
            BuyRequest storage request = buyRequests[userRequests[i]];
            requests[i] = BuyRequestPublic({
                fulfilled: request.fulfilled,
                claimed: request.claimed,
                cancelled: request.cancelled,
                user: request.user,
                pair: request.pair,
                nftAmount: request.nftAmount,
                inputAmount: request.inputAmount,
                claimedTokenIds: request.claimedTokenIds,
                timestamp: request.timestamp
            });
        }
    }

    // =========================================
    // Admin Functions
    // =========================================

    /**
     * @notice Updates the fee and fee recipient for the wrapper contract.
     * @param _newFee The new fee to be set.
     * @param _newFeeRecipient The new fee recipient to be set.
     */
    function setFeeConfig(
        uint256 _newFee,
        address _newFeeRecipient
    ) external onlyOwner {
        require(_newFee <= MAX_FEE, "Additional fee must be less than 5%");
        require(_newFeeRecipient != address(0), "Invalid address");

        fee = _newFee;
        feeRecipient = _newFeeRecipient;
        emit FeeConfigUpdated(_newFee, _newFeeRecipient);
    }

    /**
     * @notice Sets the VRF consumer contract address.
     * @param _newVRFConsumer The new VRF consumer contract address.
     */
    function setVRFConsumer(address _newVRFConsumer) external onlyOwner {
        require(_newVRFConsumer != address(0), "Invalid address");

        vrfConsumer = IVRFConsumer(_newVRFConsumer);
        emit VRFConsumerUpdated(_newVRFConsumer);
    }

    /**
     * @notice Sets the allow list hook contract address.
     * @param _newAllowListHook The new allow list hook contract address.
     */
    function setAllowListHook(address _newAllowListHook) external onlyOwner {
        require(_newAllowListHook != address(0), "Invalid address");

        allowListHook = IAllowListHook(_newAllowListHook);
        emit AllowListHookUpdated(_newAllowListHook);
    }

    // =========================================
    // Internal Functions
    // =========================================

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

    /**
     * @notice Refunds the user with the specified amount of tokens or ETH.
     * @param to The address to refund.
     * @param amount The amount to refund.
     * @param pair The LSSVMPair involved in the transaction.
     */
    function _refundUser(address to, uint256 amount, ILSSVMPair pair) internal {
        if (_isETHPair(pair)) {
            payable(to).safeTransferETH(amount);
        } else {
            ERC20 token = pair.token();
            token.safeTransfer(to, amount);
        }
        emit Refunded(to, amount, address(pair));
    }

    /**
     * @notice Transfers the wrapper fee to the fee recipient.
     * @param amount The fee amount to transfer.
     * @param pair The LSSVMPair involved in the transaction.
     */
    function _transferFee(uint256 amount, ILSSVMPair pair) internal {
        if (_isETHPair(pair)) {
            payable(feeRecipient).safeTransferETH(amount);
        } else {
            ERC20 token = pair.token();
            token.safeTransfer(feeRecipient, amount);
        }

        emit FeeTransferred(feeRecipient, amount, address(pair));
    }

    /**
     * @notice Transfers tokens or ETH to a specified address.
     * @param to The recipient address.
     * @param amount The amount to transfer.
     * @param pair The LSSVMPair involved in the transaction.
     */
    function _transferTokens(
        address to,
        uint256 amount,
        ILSSVMPair pair
    ) internal {
        if (_isETHPair(pair)) {
            payable(to).safeTransferETH(amount);
        } else {
            ERC20 token = pair.token();
            token.safeTransfer(to, amount);
        }
    }

    /**
     * @notice Transfers multiple ERC721 or ERC1155 tokens from one address to another.
     * @param _from Address to transfer tokens from.
     * @param _to Address to transfer tokens to.
     * @param _pair The address of the pair.
     * @param _tokenIDs Array of token IDs to transfer for ERC721 or amounts for ERC1155.
     * @param _shouldApprove True if the NFTs should be approved for pair, false if not.
     */
    function _transferNFTs(
        address _from,
        address _to,
        ILSSVMPair _pair,
        uint256[] memory _tokenIDs,
        bool _shouldApprove
    ) internal {
        if (_isERC721Pair(_pair)) {
            IERC721 nft = IERC721(_pair.nft());
            for (uint256 i = 0; i < _tokenIDs.length; ) {
                nft.safeTransferFrom(_from, _to, _tokenIDs[i]);

                // Gas savings
                unchecked {
                    ++i;
                }
            }
            if (_shouldApprove) {
                nft.setApprovalForAll(address(_pair), true);
            }
        } else {
            IERC1155 nft = IERC1155(_pair.nft());
            nft.safeTransferFrom(
                _from,
                _to,
                _pair.nftId(),
                _tokenIDs[0],
                bytes("")
            );
            if (_shouldApprove) {
                nft.setApprovalForAll(address(_pair), true);
            }
        }
    }
}
