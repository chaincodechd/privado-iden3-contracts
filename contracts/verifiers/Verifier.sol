// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.27;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IRequestValidator} from "../interfaces/IRequestValidator.sol";
import {IAuthValidator} from "../interfaces/IAuthValidator.sol";
import {IState} from "../interfaces/IState.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {GenesisUtils} from "../lib/GenesisUtils.sol";

error AuthTypeNotFound(string authType);
error AuthTypeAlreadyExists(string authType);
error GroupIdNotFound(uint256 groupId);
error GroupIdAlreadyExists(uint256 groupId);
error GroupMustHaveAtLeastTwoRequests(uint256 groupID);
error LinkIDNotTheSameForGroupedRequests();
error MetadataNotSupportedYet();
error MultiRequestIdAlreadyExists(uint256 multiRequestId);
error MultiRequestIdNotFound(uint256 multiRequestId);
error NullifierSessionIDAlreadyExists(uint256 nullifierSessionID);
error ResponseFieldAlreadyExists(string responseFieldName);
error RequestIdAlreadyExists(uint256 requestId);
error RequestIdNotFound(uint256 requestId);
error RequestIdNotValid();
error RequestIdUsesReservedBytes();
error RequestIdTypeNotValid();
error RequestShouldNotHaveAGroup(uint256 requestId);
error UserIDMismatch(uint256 userIDFromAuth, uint256 userIDFromResponse);
error UserIDNotFound(uint256 userID);
error UserIDNotLinkedToAddress(uint256 userID, address userAddress);
error UserNotAuthenticated();
error ValidatorNotWhitelisted(address validator);
error VerifierIDIsNotValid(uint256 requestVerifierID, uint256 expectedVerifierID);

abstract contract Verifier is IVerifier, ContextUpgradeable {
    /// @dev Key to retrieve the linkID from the proof storage
    string private constant LINKED_PROOF_KEY = "linkID";

    struct AuthTypeData {
        IAuthValidator validator;
        bytes params;
        bool isActive;
    }

    /// @custom:storage-location erc7201:iden3.storage.Verifier
    struct VerifierStorage {
        // Information about requests
        // solhint-disable-next-line
        mapping(uint256 requestId => mapping(address sender => Proof)) _proofs;
        mapping(uint256 requestId => IVerifier.RequestData) _requests;
        uint256[] _requestIds;
        IState _state;
        mapping(uint256 groupId => uint256[] requestIds) _groupedRequests;
        uint256[] _groupIds;
        // Information about multiRequests
        mapping(uint256 multiRequestId => IVerifier.MultiRequest) _multiRequests;
        uint256[] _multiRequestIds;
        // Information about auth types and validators
        string[] _authTypes;
        mapping(string authType => AuthTypeData) _authMethods;
        mapping(uint256 nullifierSessionID => uint256 requestId) _nullifierSessionIDs;
        // verifierID to check in requests
        uint256 _verifierID;
    }

    /**
     * @dev Struct to store proof and associated data
     */
    struct Proof {
        bool isVerified;
        mapping(string key => uint256 inputValue) storageFields;
        string validatorVersion;
        uint256 blockTimestamp;
        // This empty reserved space is put in place to allow future versions
        // (see https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#storage-gaps)
        string[] keys;
        // introduce artificial shift + 1 to avoid 0 index
        mapping(string key => uint256 keyIndex) keyIndexes;
        uint256[44] __gap;
    }

    /**
     * @dev Struct to store auth proof and associated data
     */
    struct AuthProof {
        bool isVerified;
        mapping(string key => uint256 inputValue) storageFields;
        string validatorVersion;
        uint256 blockTimestamp;
        // This empty reserved space is put in place to allow future versions
        // (see https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable#storage-gaps)
        uint256[45] __gap;
    }

    // keccak256(abi.encode(uint256(keccak256("iden3.storage.Verifier")) -1 )) & ~bytes32(uint256(0xff));
    // solhint-disable-next-line const-name-snakecase
    bytes32 internal constant VerifierStorageLocation =
        0x11369addde4aae8af30dcf56fa25ad3d864848d3201d1e9197f8b4da18a51a00;

    function _getVerifierStorage() private pure returns (VerifierStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := VerifierStorageLocation
        }
    }

    bytes2 internal constant VERIFIER_ID_TYPE = 0x01A1;

    /**
     * @dev Modifier to check if the request exists
     */
    modifier checkRequestExistence(uint256 requestId, bool existence) {
        if (existence) {
            if (!requestIdExists(requestId)) {
                revert RequestIdNotFound(requestId);
            }
        } else {
            if (requestIdExists(requestId)) {
                revert RequestIdAlreadyExists(requestId);
            }
        }
        _;
    }

    /**
     * @dev Modifier to check if the multiRequest exists
     */
    modifier checkMultiRequestExistence(uint256 multiRequestId, bool existence) {
        if (existence) {
            if (!multiRequestIdExists(multiRequestId)) {
                revert MultiRequestIdNotFound(multiRequestId);
            }
        } else {
            if (multiRequestIdExists(multiRequestId)) {
                revert MultiRequestIdAlreadyExists(multiRequestId);
            }
        }
        _;
    }

    /**
     * @dev Modifier to check if the auth type exists
     */
    modifier checkAuthTypeExistence(string memory authType, bool existence) {
        if (existence) {
            if (!authTypeExists(authType)) {
                revert AuthTypeNotFound(authType);
            }
        } else {
            if (authTypeExists(authType)) {
                revert AuthTypeAlreadyExists(authType);
            }
        }
        _;
    }

    /**
     * @dev Checks if a request ID exists
     * @param requestId The ID of the request
     * @return Whether the request ID exists
     */
    function requestIdExists(uint256 requestId) public view returns (bool) {
        return
            _getVerifierStorage()._requests[requestId].validator != IRequestValidator(address(0));
    }

    /**
     * @dev Checks if a group ID exists
     * @param groupId The ID of the group
     * @return Whether the group ID exists
     */
    function groupIdExists(uint256 groupId) public view returns (bool) {
        return _getVerifierStorage()._groupedRequests[groupId].length != 0;
    }

    /**
     * @dev Checks if a multiRequest ID exists
     * @param multiRequestId The ID of the multiRequest
     * @return Whether the multiRequest ID exists
     */
    function multiRequestIdExists(uint256 multiRequestId) public view returns (bool) {
        return
            _getVerifierStorage()._multiRequests[multiRequestId].multiRequestId == multiRequestId;
    }

    /**
     * @dev Checks if an auth type exists
     * @param authType The auth type
     * @return Whether the auth type exists
     */
    function authTypeExists(string memory authType) public view returns (bool) {
        return _getVerifierStorage()._authMethods[authType].validator != IAuthValidator(address(0));
    }

    /**
     * @dev Sets different requests
     * @param requests The list of requests
     */
    function setRequests(IVerifier.Request[] calldata requests) public {
        VerifierStorage storage s = _getVerifierStorage();

        uint256 newGroupsCount = 0;
        uint256[] memory newGroupsGroupID = new uint256[](requests.length);
        uint256[] memory newGroupsRequestCount = new uint256[](requests.length);

        // 1. Check first that groupIds don't exist and keep the number of requests per group.
        for (uint256 i = 0; i < requests.length; i++) {
            uint256 groupID = requests[i].validator.getRequestParams(requests[i].params).groupID;

            if (groupID != 0) {
                if (groupIdExists(groupID)) {
                    revert GroupIdAlreadyExists(groupID);
                }

                (bool exists, uint256 groupIDIndex) = _getGroupIDIndex(
                    groupID,
                    newGroupsGroupID,
                    newGroupsCount
                );

                if (!exists) {
                    newGroupsGroupID[newGroupsCount] = groupID;
                    newGroupsRequestCount[newGroupsCount]++;
                    newGroupsCount++;
                } else {
                    newGroupsRequestCount[groupIDIndex]++;
                }
            }
        }

        _checkGroupsRequestsCount(newGroupsGroupID, newGroupsRequestCount, newGroupsCount);

        // 2. Set requests checking groups and nullifierSessionID uniqueness
        for (uint256 i = 0; i < requests.length; i++) {
            _checkRequestIdCorrectness(requests[i].requestId, requests[i].params);

            _checkNullifierSessionIdUniqueness(requests[i]);
            _checkVerifierID(requests[i]);

            uint256 groupID = requests[i].validator.getRequestParams(requests[i].params).groupID;

            _setRequest(requests[i]);

            // request with group
            if (groupID != 0) {
                // request with group
                if (!groupIdExists(groupID)) {
                    s._groupIds.push(groupID);
                }

                s._groupedRequests[groupID].push(requests[i].requestId);
            }
        }
    }

    /**
     * @dev Gets a specific request by ID
     * @param requestId The ID of the request
     * @return request The request info
     */
    function getRequest(
        uint256 requestId
    ) public view checkRequestExistence(requestId, true) returns (RequestInfo memory request) {
        VerifierStorage storage $ = _getVerifierStorage();
        IVerifier.RequestData storage rd = $._requests[requestId];
        return
            IVerifier.RequestInfo({
                requestId: requestId,
                metadata: rd.metadata,
                validator: rd.validator,
                params: rd.params,
                creator: rd.creator
            });
    }

    /**
     * @dev Sets a multiRequest
     * @param multiRequest The multiRequest data
     */
    function setMultiRequest(
        IVerifier.MultiRequest calldata multiRequest
    ) public virtual checkMultiRequestExistence(multiRequest.multiRequestId, false) {
        VerifierStorage storage s = _getVerifierStorage();
        s._multiRequests[multiRequest.multiRequestId] = multiRequest;
        s._multiRequestIds.push(multiRequest.multiRequestId);

        // checks for all the requests in this multiRequest
        _checkRequestsInMultiRequest(multiRequest.multiRequestId);
    }

    /**
     * @dev Gets a specific multiRequest by ID
     * @param multiRequestId The ID of the multiRequest
     * @return multiRequest The multiRequest data
     */
    function getMultiRequest(
        uint256 multiRequestId
    )
        public
        view
        checkMultiRequestExistence(multiRequestId, true)
        returns (IVerifier.MultiRequest memory multiRequest)
    {
        return _getVerifierStorage()._multiRequests[multiRequestId];
    }

    /**
     * @dev Submits an array of responses and updates proofs status
     * @param authResponse Auth response including auth type and proof
     * @param responses The list of responses including request ID, proof and metadata for requests
     * @param crossChainProofs The list of cross chain proofs from universal resolver (oracle). This
     * includes identities and global states.
     */
    function submitResponse(
        AuthResponse memory authResponse,
        Response[] memory responses,
        bytes memory crossChainProofs
    ) public virtual {
        VerifierStorage storage $ = _getVerifierStorage();
        address sender = _msgSender();

        // 1. Process crossChainProofs
        $._state.processCrossChainProofs(crossChainProofs);

        uint256 userIDFromAuthResponse;
        AuthTypeData storage authTypeData = $._authMethods[authResponse.authType];

        // 2. Authenticate user and get userID
        bytes32 expectedNonce = keccak256(abi.encode(sender, responses)) &
            0x0FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

        userIDFromAuthResponse = authTypeData.validator.verify(
            authResponse.proof,
            authTypeData.params,
            sender,
            $._state,
            expectedNonce
        );

        if (userIDFromAuthResponse == 0) {
            revert UserNotAuthenticated();
        }

        // 3. Verify all the responses, check userID from signals and write proof results,
        //      emit events (existing logic)
        for (uint256 i = 0; i < responses.length; i++) {
            IVerifier.Response memory response = responses[i];
            IVerifier.RequestData storage request = _getRequestIfCanBeVerified(response.requestId);

            IRequestValidator.ResponseField[] memory signals = request.validator.verify(
                response.proof,
                request.params,
                sender,
                $._state
            );

            // Check if userID from authResponse is the same as the one in the signals
            _checkUserIDMatch(userIDFromAuthResponse, signals);

            _writeProofResults(response.requestId, sender, signals);

            if (response.metadata.length > 0) {
                revert MetadataNotSupportedYet();
            }
        }
    }

    /**
     * @dev Sets an auth type
     * @param authType The auth type to add
     */
    function setAuthType(
        IVerifier.AuthType calldata authType
    ) public virtual checkAuthTypeExistence(authType.authType, false) {
        VerifierStorage storage s = _getVerifierStorage();
        s._authTypes.push(authType.authType);
        s._authMethods[authType.authType] = AuthTypeData({
            validator: authType.validator,
            params: authType.params,
            isActive: true
        });
    }

    /**
     * @dev Disables an auth type
     * @param authType The auth type to disable
     */
    function disableAuthType(
        string calldata authType
    ) public checkAuthTypeExistence(authType, true) {
        VerifierStorage storage s = _getVerifierStorage();
        s._authMethods[authType].isActive = false;
    }

    /**
     * @dev Enables an auth type
     * @param authType The auth type to enable
     */
    function enableAuthType(
        string calldata authType
    ) public checkAuthTypeExistence(authType, true) {
        VerifierStorage storage s = _getVerifierStorage();
        s._authMethods[authType].isActive = true;
    }

    /**
     * @dev Gets an auth type
     * @param authType The Id of the auth type to get
     * @return authMethod The auth type data
     */
    function getAuthType(
        string calldata authType
    ) public view checkAuthTypeExistence(authType, true) returns (AuthTypeData memory authMethod) {
        return _getVerifierStorage()._authMethods[authType];
    }

    /**
     * @dev Gets response field value
     * @param requestId Id of the request
     * @param sender Address of the user
     * @param responseFieldName Name of the response field to get
     */
    function getResponseFieldValue(
        uint256 requestId,
        address sender,
        string memory responseFieldName
    ) public view checkRequestExistence(requestId, true) returns (uint256) {
        VerifierStorage storage s = _getVerifierStorage();
        return s._proofs[requestId][sender].storageFields[responseFieldName];
    }

    /**
     * @dev Gets proof storage response fields
     * @param requestId Id of the request
     * @param sender Address of the user
     */
    function getResponseFields(
        uint256 requestId,
        address sender
    ) public view returns (IRequestValidator.ResponseField[] memory) {
        VerifierStorage storage s = _getVerifierStorage();
        Proof storage proof = s._proofs[requestId][sender];

        IRequestValidator.ResponseField[]
            memory responseFields = new IRequestValidator.ResponseField[](proof.keys.length);

        for (uint256 i = 0; i < proof.keys.length; i++) {
            responseFields[i] = IRequestValidator.ResponseField({
                name: proof.keys[i],
                value: proof.storageFields[proof.keys[i]]
            });
        }

        return responseFields;
    }

    /**
     * @dev Gets the status of the multiRequest verification
     * @param multiRequestId The ID of the multiRequest
     * @param userAddress The address of the user
     * @return status The status of the multiRequest. "True" if all requests are verified, "false" otherwise
     */
    function getMultiRequestStatus(
        uint256 multiRequestId,
        address userAddress
    )
        public
        view
        checkMultiRequestExistence(multiRequestId, true)
        returns (IVerifier.RequestStatus[] memory)
    {
        // 1. Check if all requests statuses are true for the userAddress
        IVerifier.RequestStatus[] memory requestStatus = _getMultiRequestStatus(
            multiRequestId,
            userAddress
        );

        // 2. Check if all linked response fields are the same
        bool linkedResponsesOK = _checkLinkedResponseFields(multiRequestId, userAddress);

        if (!linkedResponsesOK) {
            revert LinkIDNotTheSameForGroupedRequests();
        }

        return requestStatus;
    }

    /**
     * @dev Checks if the proofs from a Multirequest submitted for a given sender and request ID are verified
     * @param multiRequestId The ID of the multiRequest
     * @param userAddress The address of the user
     * @return status The status of the multiRequest. "True" if all requests are verified, "false" otherwise
     */
    function isMultiRequestVerified(
        uint256 multiRequestId,
        address userAddress
    ) public view checkMultiRequestExistence(multiRequestId, true) returns (bool) {
        // 1. Check if all requests are verified for the userAddress
        bool verified = _isMultiRequestVerified(multiRequestId, userAddress);

        if (verified) {
            // 2. Check if all linked response fields are the same
            bool linkedResponsesOK = _checkLinkedResponseFields(multiRequestId, userAddress);

            if (!linkedResponsesOK) {
                verified = false;
            }
        }

        return verified;
    }

    /**
     * @dev Checks if a proof from a request submitted for a given sender and request ID is verified
     * @param sender The sender's address
     * @param requestId The ID of the request
     * @return True if proof is verified
     */
    function isRequestVerified(
        address sender,
        uint256 requestId
    ) public view checkRequestExistence(requestId, true) returns (bool) {
        VerifierStorage storage s = _getVerifierStorage();
        return s._proofs[requestId][sender].isVerified;
    }

    /**
     * @dev Get the requests count.
     * @return Requests count.
     */
    function getRequestsCount() public view returns (uint256) {
        return _getVerifierStorage()._requestIds.length;
    }

    /**
     * @dev Get the group of requests count.
     * @return Group of requests count.
     */
    function getGroupsCount() public view returns (uint256) {
        return _getVerifierStorage()._groupIds.length;
    }

    /**
     * @dev Get the group of requests.
     * @return Group of requests.
     */
    function getGroupedRequests(
        uint256 groupID
    ) public view returns (IVerifier.RequestInfo[] memory) {
        VerifierStorage storage s = _getVerifierStorage();

        IVerifier.RequestInfo[] memory requests = new IVerifier.RequestInfo[](
            s._groupedRequests[groupID].length
        );

        for (uint256 i = 0; i < s._groupedRequests[groupID].length; i++) {
            uint256 requestId = s._groupedRequests[groupID][i];
            IVerifier.RequestData storage rd = s._requests[requestId];

            requests[i] = IVerifier.RequestInfo({
                requestId: requestId,
                metadata: rd.metadata,
                validator: rd.validator,
                params: rd.params,
                creator: rd.creator
            });
        }

        return requests;
    }

    /**
     * @dev Gets the address of the state contract linked to the verifier
     * @return address State contract address
     */
    function getStateAddress() public view virtual returns (address) {
        return address(_getVerifierStorage()._state);
    }

    /**
     * @dev Gets the verifierID of the verifier contract
     * @return uint256 verifierID of the verifier contract
     */
    function getVerifierID() public view virtual returns (uint256) {
        return _getVerifierStorage()._verifierID;
    }

    /**
     * @dev Checks the proof status for a given user and request ID
     * @param sender The sender's address
     * @param requestId The ID of the ZKP request
     * @return The proof status structure
     */
    function getRequestStatus(
        address sender,
        uint256 requestId
    ) public view checkRequestExistence(requestId, true) returns (IVerifier.RequestStatus memory) {
        VerifierStorage storage s = _getVerifierStorage();
        Proof storage proof = s._proofs[requestId][sender];

        return
            IVerifier.RequestStatus(
                requestId,
                proof.isVerified,
                proof.validatorVersion,
                proof.blockTimestamp
            );
    }

    function _setState(IState state) internal {
        _getVerifierStorage()._state = state;
    }

    // solhint-disable-next-line func-name-mixedcase
    function __Verifier_init(IState state) internal onlyInitializing {
        __Verifier_init_unchained(state);
    }

    // solhint-disable-next-line func-name-mixedcase
    function __Verifier_init_unchained(IState state) internal onlyInitializing {
        _setState(state);
        // initial calculation of verifierID from contract address and verifier id type defined
        uint256 calculatedVerifierID = GenesisUtils.calcIdFromEthAddress(
            VERIFIER_ID_TYPE,
            address(this)
        );
        _setVerifierID(calculatedVerifierID);
    }

    function _setVerifierID(uint256 verifierID) internal {
        VerifierStorage storage s = _getVerifierStorage();
        s._verifierID = verifierID;
    }

    function _setRequest(
        Request calldata request
    ) internal virtual checkRequestExistence(request.requestId, false) {
        VerifierStorage storage s = _getVerifierStorage();

        s._requests[request.requestId] = IVerifier.RequestData({
            metadata: request.metadata,
            validator: request.validator,
            params: request.params,
            creator: _msgSender()
        });
        s._requestIds.push(request.requestId);
    }

    function _checkVerifierID(IVerifier.Request calldata request) internal view {
        VerifierStorage storage s = _getVerifierStorage();
        uint256 requestVerifierID = request.validator.getRequestParams(request.params).verifierID;

        if (requestVerifierID != 0) {
            if (requestVerifierID != s._verifierID) {
                revert VerifierIDIsNotValid(requestVerifierID, s._verifierID);
            }
        }
    }

    function _getRequestType(uint256 requestId) internal pure returns (uint8) {
        // 0x0000000000000000 - prefix for old uint64 requests
        // 0x0000000000000001 - prefix for keccak256 cut to fit in the remaining 192 bits
        return uint8(requestId >> 192);
    }

    function _checkRequestIdCorrectness(
        uint256 requestId,
        bytes calldata requestParams
    ) internal pure {
        // 1. Check prefix
        uint8 requestType = _getRequestType(requestId);
        if (requestType >= 2) {
            revert RequestIdTypeNotValid();
        }
        // 2. Check reserved bytes
        if ((requestId >> 200) > 0) {
            revert RequestIdUsesReservedBytes();
        }
        // 3. Check if requestId matches the hash of the requestParams
        if (requestType == 1) {
            uint256 hashValue = uint256(keccak256(requestParams));
            if (
                requestId !=
                (hashValue & 0x0000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) +
                    0x0000000000000001000000000000000000000000000000000000000000000000
            ) {
                revert RequestIdNotValid();
            }
        }
    }

    function _checkNullifierSessionIdUniqueness(IVerifier.Request calldata request) internal {
        VerifierStorage storage s = _getVerifierStorage();
        uint256 nullifierSessionID = request
            .validator
            .getRequestParams(request.params)
            .nullifierSessionID;
        if (nullifierSessionID != 0) {
            if (s._nullifierSessionIDs[nullifierSessionID] != 0) {
                revert NullifierSessionIDAlreadyExists(nullifierSessionID);
            }
            s._nullifierSessionIDs[nullifierSessionID] = nullifierSessionID;
        }
    }

    function _getGroupIDIndex(
        uint256 groupID,
        uint256[] memory groupList,
        uint256 listCount
    ) internal pure returns (bool, uint256) {
        for (uint256 j = 0; j < listCount; j++) {
            if (groupList[j] == groupID) {
                return (true, j);
            }
        }

        return (false, 0);
    }

    function _checkGroupsRequestsCount(
        uint256[] memory groupList,
        uint256[] memory groupRequestsList,
        uint256 groupsCount
    ) internal pure {
        for (uint256 i = 0; i < groupsCount; i++) {
            if (groupRequestsList[i] < 2) {
                revert GroupMustHaveAtLeastTwoRequests(groupList[i]);
            }
        }
    }

    function _checkRequestsInMultiRequest(uint256 multiRequestId) internal view {
        VerifierStorage storage s = _getVerifierStorage();

        uint256[] memory requestIds = s._multiRequests[multiRequestId].requestIds;
        uint256[] memory groupIds = s._multiRequests[multiRequestId].groupIds;

        // check that all the single requests doesn't have group
        for (uint256 i = 0; i < requestIds.length; i++) {
            if (!requestIdExists(requestIds[i])) {
                revert RequestIdNotFound(requestIds[i]);
            }
            IRequestValidator.RequestParams memory requestParams = s
                ._requests[requestIds[i]]
                .validator
                .getRequestParams(s._requests[requestIds[i]].params);
            if (requestParams.groupID != 0) {
                revert RequestShouldNotHaveAGroup(requestIds[i]);
            }
        }

        for (uint256 i = 0; i < groupIds.length; i++) {
            if (!groupIdExists(groupIds[i])) {
                revert GroupIdNotFound(groupIds[i]);
            }
        }
    }

    function _checkUserIDMatch(
        uint256 userIDFromAuthResponse,
        IRequestValidator.ResponseField[] memory signals
    ) internal pure {
        for (uint256 j = 0; j < signals.length; j++) {
            if (
                keccak256(abi.encodePacked(signals[j].name)) ==
                keccak256(abi.encodePacked("userID"))
            ) {
                if (userIDFromAuthResponse != signals[j].value) {
                    revert UserIDMismatch(userIDFromAuthResponse, signals[j].value);
                }
            }
        }
    }

    /**
     * @dev Updates a request
     * @param request The request data
     */
    function _updateRequest(
        IVerifier.Request calldata request
    ) internal checkRequestExistence(request.requestId, true) {
        VerifierStorage storage s = _getVerifierStorage();

        s._requests[request.requestId] = IVerifier.RequestData({
            metadata: request.metadata,
            validator: request.validator,
            params: request.params,
            creator: _msgSender()
        });
    }

    function _checkLinkedResponseFields(
        uint256 multiRequestId,
        address sender
    ) internal view returns (bool) {
        VerifierStorage storage s = _getVerifierStorage();

        for (uint256 i = 0; i < s._multiRequests[multiRequestId].groupIds.length; i++) {
            uint256 groupId = s._multiRequests[multiRequestId].groupIds[i];

            // Check linkID in the same group or requests is the same
            uint256 requestLinkID = getResponseFieldValue(
                s._groupedRequests[groupId][0],
                sender,
                LINKED_PROOF_KEY
            );
            for (uint256 j = 1; j < s._groupedRequests[groupId].length; j++) {
                uint256 requestLinkIDToCompare = getResponseFieldValue(
                    s._groupedRequests[groupId][j],
                    sender,
                    LINKED_PROOF_KEY
                );
                if (requestLinkID != requestLinkIDToCompare) {
                    return false;
                }
            }
        }

        return true;
    }

    function _getMultiRequestStatus(
        uint256 multiRequestId,
        address userAddress
    ) internal view returns (IVerifier.RequestStatus[] memory) {
        VerifierStorage storage s = _getVerifierStorage();
        IVerifier.MultiRequest storage multiRequest = s._multiRequests[multiRequestId];

        uint256 lengthGroupIds;

        if (multiRequest.groupIds.length > 0) {
            for (uint256 i = 0; i < multiRequest.groupIds.length; i++) {
                uint256 groupId = multiRequest.groupIds[i];
                lengthGroupIds += s._groupedRequests[groupId].length;
            }
        }

        IVerifier.RequestStatus[] memory requestStatus = new IVerifier.RequestStatus[](
            multiRequest.requestIds.length + lengthGroupIds
        );

        for (uint256 i = 0; i < multiRequest.requestIds.length; i++) {
            uint256 requestId = multiRequest.requestIds[i];

            requestStatus[i] = IVerifier.RequestStatus({
                requestId: requestId,
                isVerified: s._proofs[requestId][userAddress].isVerified,
                validatorVersion: s._proofs[requestId][userAddress].validatorVersion,
                timestamp: s._proofs[requestId][userAddress].blockTimestamp
            });
        }

        for (uint256 i = 0; i < multiRequest.groupIds.length; i++) {
            uint256 groupId = multiRequest.groupIds[i];

            for (uint256 j = 0; j < s._groupedRequests[groupId].length; j++) {
                uint256 requestId = s._groupedRequests[groupId][j];

                requestStatus[multiRequest.requestIds.length + j] = IVerifier.RequestStatus({
                    requestId: requestId,
                    isVerified: s._proofs[requestId][userAddress].isVerified,
                    validatorVersion: s._proofs[requestId][userAddress].validatorVersion,
                    timestamp: s._proofs[requestId][userAddress].blockTimestamp
                });
            }
        }

        return requestStatus;
    }

    function _isMultiRequestVerified(
        uint256 multiRequestId,
        address userAddress
    ) internal view returns (bool) {
        VerifierStorage storage s = _getVerifierStorage();
        IVerifier.MultiRequest storage multiRequest = s._multiRequests[multiRequestId];

        for (uint256 i = 0; i < multiRequest.requestIds.length; i++) {
            uint256 requestId = multiRequest.requestIds[i];

            if (!s._proofs[requestId][userAddress].isVerified) {
                return false;
            }
        }

        for (uint256 i = 0; i < multiRequest.groupIds.length; i++) {
            uint256 groupId = multiRequest.groupIds[i];

            for (uint256 j = 0; j < s._groupedRequests[groupId].length; j++) {
                uint256 requestId = s._groupedRequests[groupId][j];

                if (!s._proofs[requestId][userAddress].isVerified) {
                    return false;
                }
            }
        }

        return true;
    }

    function _getRequestIfCanBeVerified(
        uint256 requestId
    )
        internal
        view
        virtual
        checkRequestExistence(requestId, true)
        returns (IVerifier.RequestData storage)
    {
        VerifierStorage storage $ = _getVerifierStorage();
        return $._requests[requestId];
    }

    /**
     * @dev Writes proof results.
     * @param requestId The request ID of the proof
     * @param sender The address of the sender of the proof
     * @param responseFields The array of response fields of the proof
     */
    function _writeProofResults(
        uint256 requestId,
        address sender,
        IRequestValidator.ResponseField[] memory responseFields
    ) internal {
        VerifierStorage storage s = _getVerifierStorage();
        Proof storage proof = s._proofs[requestId][sender];

        // We only keep only 1 proof now without history. Prepared for the future if needed.
        for (uint256 i = 0; i < responseFields.length; i++) {
            proof.storageFields[responseFields[i].name] = responseFields[i].value;
            if (proof.keyIndexes[responseFields[i].name] == 0) {
                proof.keys.push(responseFields[i].name);
                proof.keyIndexes[responseFields[i].name] = proof.keys.length;
            } else {
                revert ResponseFieldAlreadyExists(responseFields[i].name);
            }
        }

        proof.isVerified = true;
        proof.validatorVersion = s._requests[requestId].validator.version();
        proof.blockTimestamp = block.timestamp;
    }
}
