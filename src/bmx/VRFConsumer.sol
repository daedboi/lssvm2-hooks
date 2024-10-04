// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRFConsumerBaseV2Plus} from "./chainlink-vrf-v2.5/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "./chainlink-vrf-v2.5/VRFV2PlusClient.sol";
import {ISudoVRFRouter} from "./Interfaces.sol";

/**
 * @title VRFConsumer
 * @notice This contract is used to consume randomness from the Chainlink VRF service.
 * @dev Assumes you have a valid subscription ID and the service is funded.
 */
contract VRFConsumer is VRFConsumerBaseV2Plus {
    // =========================================
    // Constants and Immutable Variables
    // =========================================

    /// @notice The maximum callback gas limit for VRF requests.
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;

    /// @notice The maximum number of random words that can be requested in a single request.
    uint32 public constant MAX_RANDOM_WORDS = 500;

    /// @notice The maximum number of confirmations for a VRF request.
    uint16 public constant MAX_REQUEST_CONFIRMATIONS = 200;

    /// @notice The subscription ID for the VRF requests.
    uint256 public immutable s_subscriptionId;

    /// @notice The VRF coordinator contract address.
    address public immutable vrfCoordinatorContract =
        0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;

    // =========================================
    // State Variables
    // =========================================

    /// @notice Mapping from request ID to request status.
    mapping(uint256 => RequestStatus) public s_requests;

    /// @notice The SudoVRFRouter contract instance.
    ISudoVRFRouter public sudoVRFRouter;

    /// @notice The key hash for the VRF requests (2 gwei default).
    bytes32 public keyHash =
        0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab;

    /// @notice The callback gas limit for the VRF requests.
    uint32 public callbackGasLimit = 500_000;

    /// @notice The number of confirmations for the VRF requests.
    uint16 public requestConfirmations = 3;

    /// @notice Whether to use native payment for the VRF requests (ETH or LINK).
    bool public enableNativePayment = true;

    // =========================================
    // Structs
    // =========================================

    /// @notice Struct representing the status of a VRF request.
    struct RequestStatus {
        bool fulfilled; // if the request has been successfully fulfilled
        bool exists; // if a requestId exists
    }

    // =========================================
    // Events
    // =========================================

    event RequestSent(uint256 requestId);
    event RequestFulfilled(uint256 requestId);
    event SudoVRFRouterSet(address sudoVRFRouter);
    event VRFConfigUpdated(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bytes32 keyHash,
        bool enableNativePayment
    );

    // =========================================
    // Constructor
    // =========================================

    constructor(
        uint256 _subscriptionId
    ) VRFConsumerBaseV2Plus(vrfCoordinatorContract) {
        s_subscriptionId = _subscriptionId;
    }

    // =========================================
    // Modifiers
    // =========================================

    modifier onlySudoVRFRouter() {
        require(
            msg.sender == address(sudoVRFRouter),
            "Only the SudoVRFRouter can call this function"
        );
        _;
    }

    // =========================================
    // External Functions
    // =========================================

    /**
     * @notice Requests random words from the VRF service.
     * @param _numWords The number of random words to request.
     * @return requestId The ID of the request.
     */
    function requestRandomWords(
        uint32 _numWords
    ) external onlySudoVRFRouter returns (uint256 requestId) {
        require(_numWords <= MAX_RANDOM_WORDS, "Too many random words");
        // Will revert if subscription is not set and funded.
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: s_subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: _numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: enableNativePayment
                    })
                )
            })
        );
        s_requests[requestId] = RequestStatus({exists: true, fulfilled: false});

        emit RequestSent(requestId);
        return requestId;
    }

    // =========================================
    // Admin Functions
    // =========================================

    /**
     * @notice Set the SudoVRFRouter contract.
     * @param _sudoVRFRouter The address of the SudoVRFRouter contract.
     */
    function setSudoVRFRouter(
        address payable _sudoVRFRouter
    ) external onlyOwner {
        sudoVRFRouter = ISudoVRFRouter(_sudoVRFRouter);

        emit SudoVRFRouterSet(_sudoVRFRouter);
    }

    /**
     * @notice Set the VRF config.
     * @param _callbackGasLimit The callback gas limit.
     * @param _requestConfirmations The request confirmations.
     * @param _keyHash The key hash.
     * @param _enableNativePayment Whether to use native payment for the VRF requests.
     */
    function setVRFConfig(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        bytes32 _keyHash,
        bool _enableNativePayment
    ) external onlyOwner {
        require(
            _callbackGasLimit <= MAX_CALLBACK_GAS_LIMIT &&
                _callbackGasLimit > 0,
            "Invalid callback gas limit"
        );
        require(
            _requestConfirmations <= MAX_REQUEST_CONFIRMATIONS &&
                _requestConfirmations > 0,
            "Invalid request confirmations"
        );
        require(_keyHash != bytes32(0), "Invalid key hash");
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        keyHash = _keyHash;
        enableNativePayment = _enableNativePayment;

        emit VRFConfigUpdated(
            _callbackGasLimit,
            _requestConfirmations,
            _keyHash,
            _enableNativePayment
        );
    }

    // =========================================
    // Internal Functions
    // =========================================

    /**
     * @notice Fulfill the VRF request.
     * @param _requestId The ID of the request.
     * @param _randomWords The random words.
     */
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        // store results in SudoVRFRouter buyRequests
        sudoVRFRouter.buyNFTsCallback(_requestId, _randomWords);

        s_requests[_requestId].fulfilled = true;
        emit RequestFulfilled(_requestId);
    }
}
