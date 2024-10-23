// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {ILSSVMPairFactory, ILSSVMPair, IVRFConsumer, ISudoFactoryWrapper, IAllowListHook} from "./Interfaces.sol";

/**
 * @title SudoVRFRouter
 * @author 0xdaedboi
 * @notice This contract is used as a router for buying and selling SudoSwap pairs with Chainlink randomness enabled for buying NFTs.
 */
contract SudoVRFRouter is Ownable2Step, ReentrancyGuard, ERC721Holder {
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

    /// @notice SudoSingleFactoryWrapper contract instance
    ISudoFactoryWrapper public immutable singleFactoryWrapper;

    // =========================================
    // State Variables
    // =========================================

    /// @notice VRFConsumer contract instance
    IVRFConsumer public vrfConsumer;

    /// @notice AllowListHook contract instance
    IAllowListHook public allowListHook;

    /// @notice The current main fee percentage, applies to all multi-asset sell listings and any buy listings
    uint256 public fee;

    /// @notice The fee recipient address
    address public feeRecipient;

    /// @notice Mapping from collection address to the fee for single-asset sell listings
    mapping(address => uint256) public collectionToFeeSingle;

    /// @notice Mapping from user address to their request IDs
    mapping(address => uint256[]) private userToRequestIds;

    /// @notice Mapping from request ID to BuyRequest
    mapping(uint256 => BuyRequest) private buyRequests;

    /// @notice Mapping from pair or user to whether it is allowed to send NFTs to the router
    /// @dev This is to enforce the AllowListHook
    mapping(address => bool) public allowedSenders;

    // =========================================
    // Structs
    // =========================================

    /// @notice Struct representing a buy request for random NFTs
    struct BuyRequest {
        bool cancelled;
        address user;
        address pair;
        uint256 nftAmount;
        uint256 inputAmount;
        uint256 timestamp;
        uint256[] claimedTokenIds;
    }

    // =========================================
    // Events
    // =========================================

    event NFTsBought(
        address indexed pair,
        address indexed buyer,
        uint256[] nftIds,
        uint256 finalPrice,
        uint256 indexed requestId
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
    event CollectionFeeUpdated(address indexed nft, uint256 newFee);
    event VRFConsumerUpdated(address newVRFConsumer);
    event AllowListHookUpdated(address newAllowListHook);
    event RequestSubmitted(address indexed user, uint256 indexed requestId);
    event RequestCancelled(address indexed user, uint256 indexed requestId);
    event RequestFailed(address indexed user, uint256 indexed requestId);
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
     * @param _singleFactoryWrapper The address of the SudoSingleFactoryWrapper contract.
     */
    constructor(
        address _vrfConsumer,
        uint256 _fee,
        address _feeRecipient,
        address _factoryWrapper,
        address _singleFactoryWrapper
    ) {
        require(
            _vrfConsumer != address(0) &&
                _feeRecipient != address(0) &&
                _factoryWrapper != address(0) &&
                _singleFactoryWrapper != address(0),
            "Invalid addresses"
        );
        require(_fee <= MAX_FEE, "Wrapper fee cannot be greater than 5%");

        vrfConsumer = IVRFConsumer(_vrfConsumer);
        fee = _fee;
        feeRecipient = _feeRecipient;
        factoryWrapper = ISudoFactoryWrapper(_factoryWrapper);
        singleFactoryWrapper = ISudoFactoryWrapper(_singleFactoryWrapper);
    }

    receive() external payable {
        revert("Not payable");
    }

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
     * @notice Callback function called by the VRFConsumer to deliver randomness and perform the buy.
     * @dev This function should not revert, otherwise VRF will not respond again.
     * @param _requestId The VRF request ID.
     * @param _randomWords The random numbers provided by VRF.
     */
    function buyNFTsCallback(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) external nonReentrant onlyVRFConsumer {
        // VRFConsumer will only call this function for valid requests
        BuyRequest storage request = buyRequests[_requestId];
        address user = request.user;

        // Ensure the request is not already claimed or cancelled
        if (request.claimedTokenIds.length > 0 || request.cancelled) {
            emit RequestFailed(user, _requestId);
            return;
        }

        ILSSVMPair pair = ILSSVMPair(request.pair);
        uint256[] memory allPairNFTIds = pair.getAllIds();

        if (
            request.nftAmount > allPairNFTIds.length ||
            _randomWords.length < request.nftAmount
        ) {
            // Not enough NFTs or random results; refund the user
            request.cancelled = true;
            _transferTokens(user, request.inputAmount, pair, true);
            emit RequestFailed(user, _requestId);
            return;
        }

        (uint256 finalPrice, uint256 wrapperFee, ) = calculateBuyOrSell(
            request.pair,
            request.nftAmount,
            true, // It's a buy operation
            false // Not a single-asset buy
        );

        if (request.inputAmount < finalPrice) {
            // Insufficient funds; refund the user
            request.cancelled = true;
            _transferTokens(user, request.inputAmount, pair, true);
            emit RequestFailed(user, _requestId);
            return;
        }

        // Get the amount to swap for the NFTs incl. any slippage set
        uint256 swapAmount = request.inputAmount - wrapperFee;

        // Get random NFT IDs from allPairNFTIds using _randomWords
        uint256[] memory randomNFTIds = new uint256[](request.nftAmount);
        uint256 n = allPairNFTIds.length;
        for (uint256 i = 0; i < request.nftAmount; ) {
            uint256 randomIndex = _randomWords[i] % n;
            randomNFTIds[i] = allPairNFTIds[randomIndex];

            // Move the last element to the place of the used one
            n--;
            if (randomIndex != n) {
                allPairNFTIds[randomIndex] = allPairNFTIds[n];
            }

            unchecked {
                ++i;
            }
        }

        // Mark the pair as allowed before initiating the swap
        allowedSenders[request.pair] = true;
        // Perform the swap through the pair
        try
            pair.swapTokenForSpecificNFTs(
                randomNFTIds,
                swapAmount,
                address(this),
                false,
                address(this)
            )
        returns (uint256 _amountUsed) {
            // Unmark the pair as allowed
            allowedSenders[request.pair] = false;

            // Transfer NFTs to user
            _transferNFTs(address(this), user, pair, randomNFTIds, false); // Transfer NFTs to user

            // Transfer fee to fee recipient
            _transferTokens(feeRecipient, wrapperFee, pair, false);

            // Return the leftover to user
            if (_amountUsed < swapAmount) {
                _transferTokens(
                    request.user,
                    swapAmount - _amountUsed,
                    pair,
                    false
                );
            }
        } catch {
            // Unmark the pair as allowed
            allowedSenders[request.pair] = false;

            // Reset claimed state
            request.cancelled = true;

            // Refund user
            _transferTokens(user, request.inputAmount, pair, true);

            emit RequestFailed(user, _requestId);
            return;
        }

        request.claimedTokenIds = randomNFTIds;

        emit NFTsBought(
            request.pair,
            request.user,
            randomNFTIds,
            finalPrice,
            _requestId
        );
    }

    /**
     * @notice Allows a user to cancel an unfulfilled VRF request and retrieve their funds.
     * @param requestId The ID of the VRF request to cancel.
     */
    function cancelUnfulfilledRequest(uint256 requestId) external nonReentrant {
        BuyRequest storage request = buyRequests[requestId];
        require(request.user == msg.sender, "Not your request");
        require(
            !request.cancelled && request.claimedTokenIds.length == 0,
            "Request already fulfilled or cancelled"
        );
        require(
            block.timestamp >= request.timestamp + CANCELLATION_DELAY,
            "Wait before cancelling"
        );

        request.cancelled = true;
        // Refund the user
        _transferTokens(
            msg.sender,
            request.inputAmount,
            ILSSVMPair(request.pair),
            true
        );

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
    ) external nonReentrant returns (uint256 requestId) {
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
                buyRequests[lastRequestId].claimedTokenIds.length != 0 ||
                    buyRequests[lastRequestId].cancelled,
                "User has an unfulfilled buy request which is not cancelled"
            );
        }

        ILSSVMPair pair = ILSSVMPair(_pair);
        require(_nftAmount <= pair.getAllIds().length, "Not enough NFTs");

        (uint256 finalPrice, , ) = calculateBuyOrSell(
            _pair,
            _nftAmount,
            true, // It's a buy operation
            false // Not a single-asset buy
        );
        require(
            _maxExpectedTokenInput >= finalPrice,
            "Insufficient funds to buy NFTs"
        );

        ERC20 token = pair.token();

        // Transfer tokens from the buyer to this contract and approve the pair
        token.safeTransferFrom(
            msg.sender,
            address(this),
            _maxExpectedTokenInput
        );
        pair.token().safeApprove(_pair, _maxExpectedTokenInput);

        requestId = vrfConsumer.requestRandomWords(uint32(_nftAmount));
        buyRequests[requestId] = BuyRequest({
            cancelled: false,
            user: msg.sender,
            pair: _pair,
            nftAmount: _nftAmount,
            inputAmount: _maxExpectedTokenInput,
            claimedTokenIds: new uint256[](0),
            timestamp: block.timestamp
        });
        userToRequestIds[msg.sender].push(requestId);

        emit RequestSubmitted(msg.sender, requestId);
    }

    /**
     * @notice Buys one NFT without VRF from a single-asset sell pool.
     * @param _pair The address of the pair to buy from.
     * @param _maxExpectedTokenInput The maximum token input expected (including fees and slippage).
     */
    function buySingleNFT(
        address _pair,
        uint256 _maxExpectedTokenInput
    ) external nonReentrant {
        require(
            singleFactoryWrapper.isPair(_pair),
            "Pair is not a single-asset pair"
        );
        require(_maxExpectedTokenInput > 0, "Invalid _maxExpectedTokenInput");
        require(
            block.timestamp < singleFactoryWrapper.getUnlockTime(_pair) ||
                singleFactoryWrapper.getUnlockTime(_pair) == 0,
            "Can only buy before pair is unlocked or from initially unlocked pair"
        );

        (uint256 finalPrice, uint256 wrapperFee, ) = calculateBuyOrSell(
            _pair,
            1, // 1 NFT
            true, // It's a buy operation
            true // It's a single-asset buy
        );
        require(
            _maxExpectedTokenInput >= finalPrice,
            "Insufficient funds to buy NFT"
        );

        ILSSVMPair pair = ILSSVMPair(_pair);
        uint256[] memory pairNFTIds = pair.getAllIds(); // this should return 1 NFT
        ERC20 token = pair.token();

        // Transfer tokens from the buyer to this contract and approve the pair
        token.safeTransferFrom(
            msg.sender,
            address(this),
            _maxExpectedTokenInput
        );
        token.safeApprove(_pair, _maxExpectedTokenInput);

        // Get the amount to swap for the NFTs incl. any slippage set
        uint256 swapAmount = _maxExpectedTokenInput - wrapperFee;

        // Mark the pair as allowed before initiating the swap
        allowedSenders[_pair] = true;

        // Perform the swap through the pair
        uint256 amountUsed = pair.swapTokenForSpecificNFTs(
            pairNFTIds,
            swapAmount,
            address(this),
            false,
            address(this)
        );

        // Unmark the pair as allowed
        allowedSenders[_pair] = false;

        // Transfer NFT to user
        _transferNFTs(address(this), msg.sender, pair, pairNFTIds, false);

        // Transfer fee to fee recipient
        _transferTokens(feeRecipient, wrapperFee, pair, false);

        // Return the leftover to user
        if (amountUsed < swapAmount) {
            _transferTokens(msg.sender, swapAmount - amountUsed, pair, false);
        }

        emit NFTsBought(_pair, msg.sender, pairNFTIds, finalPrice, 0);
    }

    /**
     * @notice Sells NFTs to a pair.
     * @param _pair The address of the pair to sell to.
     * @param _nftIds The IDs of the NFTs to sell for ERC721.
     * @param _minExpectedTokenOutput The minimum expected token output.
     * @return outputAmount The amount of tokens received after sale.
     */
    function sellNFTs(
        address _pair,
        uint256[] calldata _nftIds,
        uint256 _minExpectedTokenOutput
    ) external nonReentrant returns (uint256 outputAmount) {
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

        // Mark the pair as an allowed sender
        allowedSenders[_pair] = true;

        // Perform the swap through the pair and transfer tokens to the seller
        uint256 amountBeforeWrapperFee = pair.swapNFTsForToken(
            _nftIds,
            _minExpectedTokenOutput,
            payable(address(this)),
            false,
            address(this)
        );

        // Unmark the pair as an allowed sender
        allowedSenders[_pair] = false;

        // Calculate the  wrapper fee
        (, uint256 wrapperFee, ) = calculateBuyOrSell(
            _pair,
            _nftIds.length,
            false, // It's a sell operation
            false // Not a single-asset buy
        );
        outputAmount = amountBeforeWrapperFee - wrapperFee;

        // Transfer the wrapper fee to fee recipient and the rest to the user
        _transferTokens(feeRecipient, wrapperFee, pair, false);
        _transferTokens(msg.sender, outputAmount, pair, false);

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
     * @param _isBuy True if the operation is a buy, false if it's a sell.
     * @param _isSingleBuy True if the operation is a single-asset buy.
     * @return finalPrice The final price the user has to pay or receive.
     * @return wrapperFee The wrapper fee associated with the transaction.
     * @return royaltyAmount The royalty amount associated with the transaction.
     */
    function calculateBuyOrSell(
        address _pair,
        uint256 _nftAmount,
        bool _isBuy,
        bool _isSingleBuy
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

            // Determine the fee to apply
            uint256 finalFee = fee;
            uint256 collectionFee = collectionToFeeSingle[pair.nft()];
            if (_isSingleBuy && collectionFee > 0) {
                finalFee = collectionFee;
            }

            wrapperFee = amountExcludingFees.mulWadUp(finalFee);
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
            ) = pair.getSellNFTQuote(0, _nftAmount);

            uint256 amountExcludingFees = totalAmountReceived +
                _sudoswapFee +
                _royaltyAmount;

            // Selling only uses one fee for both single and multi asset listings
            wrapperFee = amountExcludingFees.mulWadUp(fee);
            finalPrice = totalAmountReceived - wrapperFee;
            royaltyAmount = _royaltyAmount;
        }
    }

    /**
     * @notice Returns all buy requests for a given user.
     * @param _user The address of the user.
     * @return requests An array of BuyRequest structs.
     */
    function getBuyRequests(
        address _user
    ) external view returns (BuyRequest[] memory requests) {
        uint256[] storage userRequests = userToRequestIds[_user];
        requests = new BuyRequest[](userRequests.length);
        for (uint256 i = 0; i < userRequests.length; i++) {
            BuyRequest storage request = buyRequests[userRequests[i]];
            requests[i] = BuyRequest({
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

    function setCollectionFee(
        address _nft,
        uint256 _newFee
    ) external onlyOwner {
        require(_nft != address(0), "Invalid address");
        require(_newFee <= MAX_FEE, "Fee must be less than 5%");

        collectionToFeeSingle[_nft] = _newFee;
        emit CollectionFeeUpdated(_nft, _newFee);
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

    /**
     * @notice Rescues tokens or NFTs from the contract.
     * @param _isERC20 True if the token is an ERC20, false if it's an ERC721.
     * @param _token The address of the token or NFT.
     * @param _amountOrIds The amount or IDs of the token or NFT to rescue.
     */
    function rescueTokens(
        bool _isERC20,
        address _token,
        uint256[] calldata _amountOrIds
    ) external onlyOwner {
        require(_token != address(0), "Invalid token");

        if (_isERC20) {
            require(_amountOrIds[0] > 0, "Invalid input");
            ERC20(_token).safeTransfer(msg.sender, _amountOrIds[0]);
        } else {
            require(_amountOrIds.length > 0, "Invalid input");
            for (uint256 i = 0; i < _amountOrIds.length; ) {
                IERC721(_token).transferFrom(
                    address(this),
                    msg.sender,
                    _amountOrIds[i]
                );

                // Gas savings
                unchecked {
                    ++i;
                }
            }
        }
    }

    // =========================================
    // Internal Functions
    // =========================================

    /**
     * @notice Refunds the user with the specified amount of tokens.
     * @param _to The address to refund.
     * @param _amount The amount to refund.
     * @param _pair The LSSVMPair involved in the transaction.
     * @param _isRefund True if the transfer is a refund, false if it's a transfer.
     */
    function _transferTokens(
        address _to,
        uint256 _amount,
        ILSSVMPair _pair,
        bool _isRefund
    ) internal {
        ERC20 token = _pair.token();
        token.safeTransfer(_to, _amount);

        if (_isRefund) {
            emit Refunded(_to, _amount, address(_pair));
        } else if (_to == feeRecipient) {
            emit FeeTransferred(feeRecipient, _amount, address(_pair));
        }
    }

    /**
     * @notice Transfers multiple ERC721 tokens from one address to another.
     * @param _from Address to transfer tokens from.
     * @param _to Address to transfer tokens to.
     * @param _pair The address of the pair.
     * @param _tokenIDs Array of token IDs to transfer for ERC721.
     * @param _shouldApprove True if the NFTs should be approved for pair, false if not.
     */
    function _transferNFTs(
        address _from,
        address _to,
        ILSSVMPair _pair,
        uint256[] memory _tokenIDs,
        bool _shouldApprove
    ) internal {
        IERC721 nft = IERC721(_pair.nft());
        for (uint256 i = 0; i < _tokenIDs.length; ) {
            nft.transferFrom(_from, _to, _tokenIDs[i]);

            // Gas savings
            unchecked {
                ++i;
            }
        }
        if (_shouldApprove) {
            nft.setApprovalForAll(address(_pair), true);
        }
    }

    // =========================================
    // Overrides
    // =========================================

    // Override onERC721Received to accept safe transfers only from allowed senders
    function onERC721Received(
        address,
        address from,
        uint256,
        bytes memory
    ) public override returns (bytes4) {
        if (!allowedSenders[from]) {
            revert("Transfer not allowed");
        }
        return this.onERC721Received.selector;
    }
}
