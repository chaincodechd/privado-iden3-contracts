// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IGroth16Verifier} from "../../interfaces/IGroth16Verifier.sol";
import {IRequestValidator} from "../../interfaces/IRequestValidator.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

error WrongCircuitID(string circuitID);
error InvalidQueryHash(uint256 expectedQueryHash, uint256 actualQueryHash);
error InvalidGroupID(uint256 groupID);
error TooManyQueries(uint256 operatorCount);
error InvalidGroth16Proof();

contract LinkedMultiQueryValidator is Ownable2StepUpgradeable, IRequestValidator, ERC165 {
    // This should be limited to the real number of queries in which operator != 0
    struct Query {
        uint256[] claimPathKey;
        uint256[] operator; // when checking SD take operator from here
        uint256[] slotIndex;
        uint256[][] value;
        uint256[] queryHash;
        string[] circuitIds;
        uint256 groupID;
        uint256 verifierID;
    }

    // keccak256(abi.encodePacked("groupID"))
    bytes32 private constant GROUPID_NAME =
        0xdab5ca4f3738dce0cd25851a4aa9160ebdfb1678ef20ca14c9a3e9217058455a;
    // keccak256(abi.encodePacked("verifierID"))
    bytes32 private constant VERIFIERID_NAME =
        0xa6ade9d39b76f319076fc4ad150ee37167dd21433b39e1d533a5d6b635762abe;
    // keccak256(abi.encodePacked("nullifierSessionID"))
    bytes32 private constant NULLIFIERSESSIONID_NAME =
        0x24cea8e4716dcdf091e4abcbd3ea617d9a5dd308b90afb5da0d75e56b3c0bc95;

    /// @dev Main storage structure for the contract
    /// @custom:storage-location iden3.storage.LinkedMultiQueryValidatorStorage
    struct LinkedMultiQueryValidatorStorage {
        mapping(string circuitName => IGroth16Verifier) _supportedCircuits;
        string[] _supportedCircuitIds;
        mapping(string => uint256) _requestParamNameToIndex;
        mapping(string => uint256) _inputNameToIndex;
    }

    // keccak256(abi.encode(uint256(keccak256("iden3.storage.LinkedMultiQueryValidator")) - 1))
    //  & ~bytes32(uint256(0xff));
    // solhint-disable-next-line const-name-snakecase
    bytes32 private constant LinkedMultiQueryValidatorStorageLocation =
        0x85875fc21d0742149175681df1689e48bce1484a73b475e15e5042650a2d7800;

    /// @dev Get the main storage using assembly to ensure specific storage location
    function _getLinkedMultiQueryValidatorStorage()
        private
        pure
        returns (LinkedMultiQueryValidatorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LinkedMultiQueryValidatorStorageLocation
        }
    }

    struct PubSignals {
        uint256 linkID;
        uint256 merklized;
        uint256[10] operatorOutput;
        uint256[10] circuitQueryHash;
    }

    string public constant VERSION = "1.0.0-beta.1";
    string internal constant CIRCUIT_ID = "linkedMultiQuery10-beta.1";
    uint256 internal constant QUERIES_COUNT = 10;

    /**
     * @dev Returns the version of the contract
     * @return The version of the contract
     */
    function version() external pure override returns (string memory) {
        return VERSION;
    }

    /**
     * @dev Initialize the contract
     * @param _groth16VerifierContractAddr Address of the verifier contract
     * @param owner Owner of the contract
     */
    function initialize(address _groth16VerifierContractAddr, address owner) public initializer {
        LinkedMultiQueryValidatorStorage storage $ = _getLinkedMultiQueryValidatorStorage();
        $._supportedCircuits[CIRCUIT_ID] = IGroth16Verifier(_groth16VerifierContractAddr);
        $._supportedCircuitIds.push(CIRCUIT_ID);

        _setInputToIndex("linkID", 0);
        _setInputToIndex("merklized", 1);
        for (uint256 i = 0; i < QUERIES_COUNT; i++) {
            _setInputToIndex(
                string(abi.encodePacked("operatorOutput_", Strings.toString(i))),
                2 + i
            );
            _setInputToIndex(
                string(abi.encodePacked("circuitQueryHash_", Strings.toString(i))),
                12 + i
            );
        }

        _setRequestParamToIndex("groupID", 0);
        _setRequestParamToIndex("verifierID", 1);
        _setRequestParamToIndex("nullifierSessionID", 2);

        __Ownable_init(owner);
    }

    /**
     * @dev Verify the proof with the supported method informed in the request query data
     * packed as bytes and that the proof was generated by the sender.
     * @param sender Sender of the proof.
     * @param proof Proof packed as bytes to verify.
     * @param params Request query data of the credential to verify.
     * @return Array of response fields as result.
     */
    function verify(
        // solhint-disable-next-line no-unused-vars
        address sender,
        bytes calldata proof,
        bytes calldata params
    ) external view returns (IRequestValidator.ResponseField[] memory) {
        LinkedMultiQueryValidatorStorage storage $ = _getLinkedMultiQueryValidatorStorage();

        Query memory query = abi.decode(params, (Query));
        (
            uint256[] memory inputs,
            uint256[2] memory a,
            uint256[2][2] memory b,
            uint256[2] memory c
        ) = abi.decode(proof, (uint256[], uint256[2], uint256[2][2], uint256[2]));
        PubSignals memory pubSignals = _parsePubSignals(inputs);

        _checkQueryHash(query, pubSignals);
        _checkGroupId(query.groupID);

        if (keccak256(bytes(query.circuitIds[0])) != keccak256(bytes(CIRCUIT_ID))) {
            revert WrongCircuitID(query.circuitIds[0]);
        }
        if (!$._supportedCircuits[CIRCUIT_ID].verify(a, b, c, inputs)) {
            revert InvalidGroth16Proof();
        }

        return _getResponseFields(pubSignals, query);
    }

    /**
     * @dev Decodes special request parameters from the request params
     * do be used by upper level clients of this contract.
     * @param params Request parameters packed as bytes.
     * @return Special request parameters extracted from the request data.
     */
    function getRequestParams(
        bytes calldata params
    ) external pure override returns (IRequestValidator.RequestParam[] memory) {
        Query memory query = abi.decode(params, (Query));
        IRequestValidator.RequestParam[]
            memory requestParams = new IRequestValidator.RequestParam[](3);
        requestParams[0] = IRequestValidator.RequestParam({name: "groupID", value: query.groupID});
        requestParams[1] = IRequestValidator.RequestParam({
            name: "verifierID",
            value: query.verifierID
        });
        requestParams[2] = IRequestValidator.RequestParam({name: "nullifierSessionID", value: 0});
        return requestParams;
    }

    /**
     * @dev Get the request param from params of the request query data.
     * @param params Request query data of the credential to verify.
     * @param paramName Request query param name to retrieve of the credential to verify.
     * @return RequestParam for the param name of the request query data.
     */
    function getRequestParam(
        bytes calldata params,
        string memory paramName
    ) external pure returns (RequestParam memory) {
        Query memory query = abi.decode(params, (Query));

        if (keccak256(bytes(paramName)) == GROUPID_NAME) {
            return IRequestValidator.RequestParam({name: paramName, value: query.groupID});
        } else if (keccak256(bytes(paramName)) == VERIFIERID_NAME) {
            return IRequestValidator.RequestParam({name: paramName, value: query.verifierID});
        } else if (keccak256(bytes(paramName)) == NULLIFIERSESSIONID_NAME) {
            return IRequestValidator.RequestParam({name: paramName, value: 0});
        } else {
            revert RequestParamNameNotFound();
        }
    }

    /**
     * @dev Get the index of the request param by name
     * @param name Name of the request param
     * @return Index of the request param
     */
    function requestParamIndexOf(
        string memory name
    ) public view virtual override returns (uint256) {
        uint256 index = _getLinkedMultiQueryValidatorStorage()._requestParamNameToIndex[name];
        if (index == 0) {
            revert RequestParamNameNotFound();
        }
        return --index; // we save 1-based index, but return 0-based
    }

    /**
     * @dev Get the index of the public input of the circuit by name
     * @param name Name of the public input
     * @return Index of the public input
     */
    function inputIndexOf(string memory name) public view virtual returns (uint256) {
        uint256 index = _getLinkedMultiQueryValidatorStorage()._inputNameToIndex[name];
        if (index == 0) {
            revert InputNameNotFound();
        }
        return --index; // we save 1-based index, but return 0-based
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IRequestValidator).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _checkGroupId(uint256 groupID) internal pure {
        if (groupID == 0) {
            revert InvalidGroupID(groupID);
        }
    }

    function _checkQueryHash(Query memory query, PubSignals memory pubSignals) internal pure {
        if (query.queryHash.length > QUERIES_COUNT) {
            revert TooManyQueries(query.queryHash.length);
        }
        for (uint256 i = 0; i < query.queryHash.length; i++) {
            if (query.queryHash[i] != pubSignals.circuitQueryHash[i]) {
                revert InvalidQueryHash(query.queryHash[i], pubSignals.circuitQueryHash[i]);
            }
        }
    }

    function _parsePubSignals(uint256[] memory inputs) internal pure returns (PubSignals memory) {
        uint256[QUERIES_COUNT] memory opsOutput;
        uint256[QUERIES_COUNT] memory queryHashes;
        PubSignals memory pubSignals = PubSignals({
            linkID: 0,
            merklized: 0,
            operatorOutput: opsOutput,
            circuitQueryHash: queryHashes
        });

        pubSignals.linkID = inputs[0];
        pubSignals.merklized = inputs[1];
        for (uint256 i = 0; i < QUERIES_COUNT; i++) {
            pubSignals.operatorOutput[i] = inputs[2 + i];
            pubSignals.circuitQueryHash[i] = inputs[2 + QUERIES_COUNT + i];
        }
        return pubSignals;
    }

    function _getResponseFields(
        PubSignals memory pubSignals,
        Query memory query
    ) internal pure returns (ResponseField[] memory) {
        uint256 operatorCount = 0;
        for (uint256 i = 0; i < query.operator.length; i++) {
            if (query.operator[i] == 16) {
                operatorCount++;
            }
        }

        uint256 n = 1;
        ResponseField[] memory rfs = new ResponseField[](n + operatorCount);
        rfs[0] = ResponseField("linkID", pubSignals.linkID);

        uint256 m = 1;
        for (uint256 i = 0; i < query.operator.length; i++) {
            // TODO consider if can be more gas efficient. Check via gasleft() first
            if (query.operator[i] == 16) {
                rfs[m++] = ResponseField(
                    string(abi.encodePacked("operatorOutput_", Strings.toString(i))),
                    pubSignals.operatorOutput[i]
                );
            }
        }

        return rfs;
    }

    function _setRequestParamToIndex(string memory requestParamName, uint256 index) internal {
        // increment index to avoid 0
        _getLinkedMultiQueryValidatorStorage()._requestParamNameToIndex[requestParamName] = ++index;
    }

    function _setInputToIndex(string memory inputName, uint256 index) internal {
        // increment index to avoid 0
        _getLinkedMultiQueryValidatorStorage()._inputNameToIndex[inputName] = ++index;
    }
}
