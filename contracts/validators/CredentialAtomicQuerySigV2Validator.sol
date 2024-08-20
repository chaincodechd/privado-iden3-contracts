// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {IVerifier} from "../interfaces/IVerifier.sol";
import {ICircuitValidator} from "../interfaces/ICircuitValidator.sol";
import {CredentialAtomicQueryV2ValidatorBase} from "./CredentialAtomicQueryV2ValidatorBase.sol";

contract CredentialAtomicQuerySigV2Validator is CredentialAtomicQueryV2ValidatorBase {
    /**
     * @dev Version of contract
     */
    string public constant VERSION = "2.0.4";

    string internal constant CIRCUIT_ID = "credentialAtomicQuerySigV2OnChain";

    function initialize(
        address _verifierContractAddr,
        address _stateContractAddr,
        address _oracleProofValidatorAddr
    ) public initializer {
        _setInputToIndex("merklized", 0);
        _setInputToIndex("userID", 1);
        _setInputToIndex("circuitQueryHash", 2);
        _setInputToIndex("issuerAuthState", 3);
        _setInputToIndex("requestID", 4);
        _setInputToIndex("challenge", 5);
        _setInputToIndex("gistRoot", 6);
        _setInputToIndex("issuerID", 7);
        _setInputToIndex("isRevocationChecked", 8);
        _setInputToIndex("issuerClaimNonRevState", 9);
        _setInputToIndex("timestamp", 10);

        _initDefaultStateVariables(_stateContractAddr, _verifierContractAddr, CIRCUIT_ID, _oracleProofValidatorAddr);
        __Ownable_init(_msgSender());
    }

    function version() public pure override returns (string memory) {
        return VERSION;
    }

    function parsePubSignals(
        uint256[] memory inputs
    ) public pure override returns (PubSignals memory) {
        PubSignals memory params = PubSignals({
            merklized: inputs[0],
            userID: inputs[1],
            circuitQueryHash: inputs[2],
            issuerState: inputs[3],
            requestID: inputs[4],
            challenge: inputs[5],
            gistRoot: inputs[6],
            issuerID: inputs[7],
            isRevocationChecked: inputs[8],
            issuerClaimNonRevState: inputs[9],
            timestamp: inputs[10]
        });

        return params;
    }
}
