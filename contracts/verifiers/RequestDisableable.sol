// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {ZKPVerifierBase} from "./ZKPVerifierBase.sol";
import {ICircuitValidator} from "../interfaces/ICircuitValidator.sol";

contract RequestDisableable is ZKPVerifierBase {
    /// @custom:storage-location erc7201:iden3.storage.RequestDisableable
    struct RequestDisableStorage {
        mapping(uint64 requestId => bool isDisabled) _requestDisabling;
    }

    // keccak256(abi.encode(uint256(keccak256("iden3.storage.RequestDisableable")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant RequestDisableStorageLocation =
        0x70325635d67d74932012fa921ccb2f335d3b1d69e3a487f50d001cc65f531600;

    function _getRequestDisableStorage() private pure returns (RequestDisableStorage storage $) {
        assembly {
            $.slot := RequestDisableStorageLocation
        }
    }

    /// @dev Modifier to check if the ZKP request is enabled
    modifier onlyEnabledRequest(uint64 requestId) {
        require(isZKPRequestEnabled(requestId), "Request is disabled");
        _;
    }

    /// @dev Submits a ZKP response and updates proof status
    /// @param requestId The ID of the ZKP request
    /// @param inputs The input data for the proof
    /// @param a The first component of the proof
    /// @param b The second component of the proof
    /// @param c The third component of the proof
    function submitZKPResponse(
        uint64 requestId,
        uint256[] memory inputs,
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c
    ) public virtual override onlyEnabledRequest(requestId) {
        super.submitZKPResponse(requestId, inputs, a, b, c);
    }

    /// @dev Verifies a ZKP response without updating any proof status
    /// @param requestId The ID of the ZKP request
    /// @param inputs The public inputs for the proof
    /// @param a The first component of the proof
    /// @param b The second component of the proof
    /// @param c The third component of the proof
    /// @param sender The sender on behalf of which the proof is done
    function verifyZKPResponse(
        uint64 requestId,
        uint256[] memory inputs,
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        address sender
    )
        public
        virtual
        override
        onlyEnabledRequest(requestId)
        returns (ICircuitValidator.Signal[] memory)
    {
        return super.verifyZKPResponse(requestId, inputs, a, b, c, sender);
    }

    /// @dev Checks if ZKP Request is enabled
    /// @param requestId The ID of the ZKP request
    /// @return True if ZKP Request enabled, otherwise returns false
    function isZKPRequestEnabled(
        uint64 requestId
    ) public view virtual checkRequestExistence(requestId, true) returns (bool) {
        return !_getRequestDisableStorage()._requestDisabling[requestId];
    }

    function _disableZKPRequest(uint64 requestId) internal checkRequestExistence(requestId, true) {
        _getRequestDisableStorage()._requestDisabling[requestId] = true;
    }

    function _enableZKPRequest(uint64 requestId) internal checkRequestExistence(requestId, true) {
        _getRequestDisableStorage()._requestDisabling[requestId] = false;
    }
}
