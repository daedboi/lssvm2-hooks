// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISudoVRFRouter} from "../bmx/Interfaces.sol";

/**
 * @title MockVRFConsumer
 * @notice A mock contract simulating the behavior of VRFConsumer for testing purposes.
 * @dev Allows calling `requestRandomWords`, and `buyNFTsCallback` can be called separately to simulate asynchronous behavior.
 */
contract MockVRFConsumer {
    // =========================================
    // State Variables
    // =========================================

    /// @notice The SudoVRFRouter contract instance.
    ISudoVRFRouter public sudoVRFRouter;

    /// @notice Mock request ID counter.
    uint256 private requestIdCounter = 1;

    /// @notice Mapping from request ID to request status.
    mapping(uint256 => bool) public s_requests;

    // =========================================
    // Events
    // =========================================

    event RequestSent(uint256 requestId);
    event RequestFulfilled(uint256 requestId);

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
     * @notice Sets the SudoVRFRouter contract.
     * @param _sudoVRFRouter The address of the SudoVRFRouter contract.
     */
    function setSudoVRFRouter(address _sudoVRFRouter) external {
        sudoVRFRouter = ISudoVRFRouter(_sudoVRFRouter);
    }

    /**
     * @notice Mock function to request random words.
     * @param _numWords The number of random words to request.
     * @return requestId The ID of the request.
     */
    function requestRandomWords(
        uint32 _numWords
    ) external onlySudoVRFRouter returns (uint256 requestId) {
        // Simulate request ID assignment
        requestId = requestIdCounter++;
        s_requests[requestId] = true;

        emit RequestSent(requestId);

        // Do not fulfill immediately; wait for explicit call to fulfillRequest

        return requestId;
    }

    /**
     * @notice Function to fulfill the random words request.
     * @param _requestId The ID of the request to fulfill.
     */
    function fulfillRandomWords(uint256 _requestId) external {
        require(s_requests[_requestId], "Request not found");

        // Create an array of one hardcoded random number
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = 42;

        // Call the buyNFTsCallback function in sudoVRFRouter
        sudoVRFRouter.buyNFTsCallback(_requestId, randomWords);

        emit RequestFulfilled(_requestId);

        // Mark the request as fulfilled
        s_requests[_requestId] = false;
    }
}
