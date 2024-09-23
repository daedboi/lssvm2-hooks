// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import "./SudoWrapper.sol";

contract RandomNumberConsumer is VRFConsumerBaseV2Plus {
  event RequestSent(uint256 requestId, uint32 numWords);
  event RequestFulfilled(uint256 requestId, uint256[] randomWords);

  struct RequestStatus {
    bool fulfilled; // if the request has been successfully fulfilled
    bool exists; // if a requestId exists
    uint256[] randomWords;
  }

  mapping(uint256 => RequestStatus) public s_requests; /* requestId --> requestStatus */

  // Your subscription ID.
  uint256 public s_subscriptionId;
  // Past request IDs.
  uint256[] public requestIds;
  uint256 public lastRequestId;
  SudoWrapper public sudoWrapper;

  bytes32 public keyHash = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;
  uint32 public callbackGasLimit = 1_000_000;
  uint16 public requestConfirmations = 3;
  uint32 public numWords = 3;
  bool public enableNativePayment = true;
  address private vrfCoordinatorContract = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;

  constructor(uint256 subscriptionId) VRFConsumerBaseV2Plus(vrfCoordinatorContract) {
    s_subscriptionId = subscriptionId;
  }

  // Assumes the subscription is funded sufficiently.
  function requestRandomWords() external returns (uint256 requestId) {
    // Will revert if subscription is not set and funded.
    requestId = s_vrfCoordinator.requestRandomWords(
      VRFV2PlusClient.RandomWordsRequest({
        keyHash: keyHash,
        subId: s_subscriptionId,
        requestConfirmations: requestConfirmations,
        callbackGasLimit: callbackGasLimit,
        numWords: numWords,
        extraArgs: VRFV2PlusClient._argsToBytes(
          VRFV2PlusClient.ExtraArgsV1({ nativePayment: enableNativePayment })
        )
      })
    );
    s_requests[requestId] = RequestStatus({
        randomWords: new uint256[](0),
        exists: true,
        fulfilled: false
    });
    requestIds.push(requestId);
    lastRequestId = requestId;
    emit RequestSent(requestId, numWords);
    return requestId;
  }

  function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
    require(s_requests[_requestId].exists, "request not found");
    // provides random numbers when calling "buyOrSellCallback"
    sudoWrapper.buyOrSellCallback(_requestId, _randomWords);

    s_requests[_requestId].fulfilled = true;
    s_requests[_requestId].randomWords = _randomWords;
    emit RequestFulfilled(_requestId, _randomWords);
  }

  function getRequestStatus(uint256 _requestId) external view returns (bool fulfilled, uint256[] memory randomWords) {
    require(s_requests[_requestId].exists, "request not found");
    RequestStatus memory request = s_requests[_requestId];
    return (request.fulfilled, request.randomWords);
  }

  function setSudoWrapper(address payable _sudoWrapper) external onlyOwner {
    sudoWrapper = SudoWrapper(_sudoWrapper);
  }

  function setCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner {
    callbackGasLimit = _callbackGasLimit;
  }

  function setRequestConfirmations(uint16 _requestConfirmations) external onlyOwner {
    requestConfirmations = _requestConfirmations;
  }

  function setNumWords(uint32 _numWords) external onlyOwner {
    numWords = _numWords;
  }

  function setKeyHash(bytes32 _keyHash) external onlyOwner {
    keyHash = _keyHash;
  }

  function setEnableNativePayment(bool _enableNativePayment) external onlyOwner {
    enableNativePayment = _enableNativePayment;
  }
}