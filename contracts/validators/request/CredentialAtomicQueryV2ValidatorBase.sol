// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.27;

import {CredentialAtomicQueryValidatorBase} from "./CredentialAtomicQueryValidatorBase.sol";
import {IGroth16Verifier} from "../../interfaces/IGroth16Verifier.sol";
import {IRequestValidator} from "../../interfaces/IRequestValidator.sol";

error CircuitsLengthShouldBeOne();
error VerifierAddressShouldNotBeZero();
error ProofIsNotValid();
error QueryHashDoesNotMatchTheRequestedOne(uint256 expected, uint256 actual);
error MerklizedValueIsNotCorrect();
error RevocationCheckShouldMatchTheQuery(uint256 expected, uint256 actual);

/**
 * @dev Base contract for credential atomic query v2 validators circuits.
 */
abstract contract CredentialAtomicQueryV2ValidatorBase is CredentialAtomicQueryValidatorBase {
    /**
     * @dev Version of contract
     */

    struct CredentialAtomicQuery {
        uint256 schema;
        uint256 claimPathKey;
        uint256 operator;
        uint256 slotIndex;
        uint256[] value;
        uint256 queryHash;
        uint256[] allowedIssuers;
        string[] circuitIds;
        bool skipClaimRevocationCheck;
        // 0 for inclusion in merklized credentials, 1 for non-inclusion and for non-merklized credentials
        uint256 claimPathNotExists;
    }

    struct PubSignals {
        uint256 merklized;
        uint256 userID;
        uint256 issuerState;
        uint256 circuitQueryHash;
        uint256 requestID;
        uint256 challenge;
        uint256 gistRoot;
        uint256 issuerID;
        uint256 isRevocationChecked;
        uint256 issuerClaimNonRevState;
        uint256 timestamp;
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

    /**
     * @dev Get the version of the contract
     * @return Version of the contract
     */
    function version() public pure virtual override returns (string memory);

    /**
     * @dev Parse the public signals
     * @param inputs Array of public inputs
     * @return Parsed public signals
     */
    function parsePubSignals(
        uint256[] memory inputs
    ) public pure virtual returns (PubSignals memory);

    /**
     * @dev Verify the groth16 proof and check the request query data
     * @param sender Sender of the proof.
     * @param proof Proof packed as bytes to verify.
     * @param params Request query data of the credential to verify.
     * @return Array of public signals as result.
     */
    function verify(
        address sender,
        bytes calldata proof,
        bytes calldata params
    ) public view override returns (IRequestValidator.ResponseField[] memory) {
        PubSignals memory pubSignals = _verifyMain(sender, proof, params);
        return _getResponseFields(pubSignals);
    }

    /**
     * @dev Get the request param from params of the request query data.
     * @param paramName Request query param name to retrieve of the credential to verify.
     * @return RequestParam for the param name of the request query data.
     */
    function getRequestParam(
        bytes calldata,
        string memory paramName
    ) external pure returns (RequestParam memory) {
        if (
            keccak256(bytes(paramName)) == GROUPID_NAME ||
            keccak256(bytes(paramName)) == VERIFIERID_NAME ||
            keccak256(bytes(paramName)) == NULLIFIERSESSIONID_NAME
        ) {
            return IRequestValidator.RequestParam({name: paramName, value: 0});
        } else {
            revert RequestParamNameNotFound();
        }
    }

    /**
     * @dev Verify the groth16 proof and check the request query data
     * @param sender Sender of the proof.
     * @param proof the groth16 proof.
     * @param params Request query data of the credential to verify.
     */
    function _verifyMain(
        address sender,
        bytes calldata proof,
        bytes calldata params
    ) internal view returns (PubSignals memory) {
        (
            uint256[] memory inputs,
            uint256[2] memory a,
            uint256[2][2] memory b,
            uint256[2] memory c
        ) = abi.decode(proof, (uint256[], uint256[2], uint256[2][2], uint256[2]));

        CredentialAtomicQuery memory credAtomicQuery = abi.decode(params, (CredentialAtomicQuery));

        if (credAtomicQuery.circuitIds.length != 1) {
            revert CircuitsLengthShouldBeOne();
        }

        IGroth16Verifier g16Verifier = getVerifierByCircuitId(credAtomicQuery.circuitIds[0]);

        if (g16Verifier == IGroth16Verifier(address(0))) {
            revert VerifierAddressShouldNotBeZero();
        }

        // verify that zkp is valid
        if (!g16Verifier.verify(a, b, c, inputs)) {
            revert ProofIsNotValid();
        }

        PubSignals memory pubSignals = parsePubSignals(inputs);

        // check circuitQueryHash
        if (pubSignals.circuitQueryHash != credAtomicQuery.queryHash) {
            revert QueryHashDoesNotMatchTheRequestedOne(
                credAtomicQuery.queryHash,
                pubSignals.circuitQueryHash
            );
        }

        _checkMerklized(pubSignals.merklized, credAtomicQuery.claimPathKey);
        _checkAllowedIssuers(pubSignals.issuerID, credAtomicQuery.allowedIssuers);
        _checkProofExpiration(pubSignals.timestamp);
        _checkIsRevocationChecked(
            pubSignals.isRevocationChecked,
            credAtomicQuery.skipClaimRevocationCheck
        );

        // Checking challenge to prevent replay attacks from other addresses
        _checkChallenge(pubSignals.challenge, sender);

        // GIST root and state checks
        _checkGistRoot(pubSignals.userID, pubSignals.gistRoot);
        _checkClaimIssuanceState(pubSignals.issuerID, pubSignals.issuerState);
        _checkClaimNonRevState(pubSignals.issuerID, pubSignals.issuerClaimNonRevState);

        return pubSignals;
    }

    function _checkMerklized(uint256 merklized, uint256 queryClaimPathKey) internal pure {
        uint256 shouldBeMerklized = queryClaimPathKey != 0 ? 1 : 0;
        if (merklized != shouldBeMerklized) {
            revert MerklizedValueIsNotCorrect();
        }
    }

    function _checkIsRevocationChecked(
        uint256 isRevocationChecked,
        bool skipClaimRevocationCheck
    ) internal pure {
        uint256 expectedIsRevocationChecked = 1;
        if (skipClaimRevocationCheck) {
            expectedIsRevocationChecked = 0;
        }
        if (isRevocationChecked != expectedIsRevocationChecked) {
            revert RevocationCheckShouldMatchTheQuery(
                expectedIsRevocationChecked,
                isRevocationChecked
            );
        }
    }

    function _getResponseFields(
        PubSignals memory pubSignals
    ) internal pure returns (IRequestValidator.ResponseField[] memory) {
        IRequestValidator.ResponseField[]
            memory responseFields = new IRequestValidator.ResponseField[](3);
        responseFields[0] = IRequestValidator.ResponseField({
            name: "userID",
            value: pubSignals.userID
        });
        responseFields[1] = IRequestValidator.ResponseField({
            name: "timestamp",
            value: pubSignals.timestamp
        });
        responseFields[2] = IRequestValidator.ResponseField({
            name: "issuerID",
            value: pubSignals.issuerID
        });
        return responseFields;
    }
}
