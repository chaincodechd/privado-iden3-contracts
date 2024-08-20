// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {CredentialAtomicQueryValidatorBase} from "./CredentialAtomicQueryValidatorBase.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {ICircuitValidator} from "../interfaces/ICircuitValidator.sol";
import {IState} from "../interfaces/IState.sol";
import {console} from "hardhat/console.sol";

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

    function version() public pure virtual override returns (string memory);

    function parsePubSignals(
        uint256[] memory inputs
    ) public pure virtual returns (PubSignals memory);

    function _verify(
        uint256[] memory inputs,
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        bytes calldata data,
        address sender,
        bytes memory crossChainProof
    ) internal view override returns (ICircuitValidator.KeyToInputValue[] memory) {
        console.log("Begin verify");
        CredentialAtomicQuery memory credAtomicQuery = abi.decode(data, (CredentialAtomicQuery));

        require(credAtomicQuery.circuitIds.length == 1, "circuitIds length is not equal to 1");

        IVerifier verifier = getVerifierByCircuitId(credAtomicQuery.circuitIds[0]);

        require(verifier != IVerifier(address(0)), "Verifier address should not be zero");

        // verify that zkp is valid
        require(verifier.verify(a, b, c, inputs), "Proof is not valid");

        PubSignals memory signals = parsePubSignals(inputs);

        // check circuitQueryHash
        require(
            signals.circuitQueryHash == credAtomicQuery.queryHash,
            "Query hash does not match the requested one"
        );

        console.log("Before checks");
        // TODO: add support for query to specific userID and then verifying it

        _checkMerklized(signals.merklized, credAtomicQuery.claimPathKey);

        _checkAllowedIssuers(signals.issuerID, credAtomicQuery.allowedIssuers);
        _checkProofExpiration(signals.timestamp);
        _checkIsRevocationChecked(
            signals.isRevocationChecked,
            credAtomicQuery.skipClaimRevocationCheck
        );

        // Checking challenge to prevent replay attacks from other addresses
        _checkChallenge(signals.challenge, sender);

        // GIST root and state checks
        (
            IState.GistRootInfo[] memory gri,
            IState.StateInfo[] memory si
        ) = _getOracleProofValidator().processProof(crossChainProof);

        if (gri.length == 1) {
            _checkGistRootExpiration(gri[0].replacedAtTimestamp);
        } else {
            _checkGistRoot(signals.gistRoot);
        }

        if (si.length == 1 && signals.issuerState != si[0].state) {
            _checkClaimIssuanceState(signals.issuerID, signals.issuerState);
        }
        if (
            si.length == 2 &&
            signals.issuerState != si[0].state &&
            signals.issuerState != si[1].state
        ) {
            _checkClaimNonRevState(signals.issuerID, signals.issuerClaimNonRevState);
        }

        if ((si.length == 1 || si.length == 2) && signals.issuerClaimNonRevState == si[0].state) {
            _checkClaimNonRevStateExpiration(si[0].replacedAtTimestamp);
        } else if (si.length == 2 && signals.issuerClaimNonRevState == si[1].state) {
            _checkClaimNonRevStateExpiration(si[1].replacedAtTimestamp);
        } else {
            _checkClaimNonRevState(signals.issuerID, signals.issuerClaimNonRevState);
        }

        // get special input values
        // selective disclosure is not supported for v2 onchain circuits
        ICircuitValidator.KeyToInputValue[] memory pairs = new ICircuitValidator.KeyToInputValue[](
            2
        );
        pairs[0] = ICircuitValidator.KeyToInputValue({key: "userID", inputValue: signals.userID});
        pairs[1] = ICircuitValidator.KeyToInputValue({
            key: "timestamp",
            inputValue: signals.timestamp
        });
        return pairs;
    }

    function _checkMerklized(uint256 merklized, uint256 queryClaimPathKey) internal pure {
        uint256 shouldBeMerklized = queryClaimPathKey != 0 ? 1 : 0;
        require(merklized == shouldBeMerklized, "Merklized value is not correct");
    }

    function _checkIsRevocationChecked(
        uint256 isRevocationChecked,
        bool skipClaimRevocationCheck
    ) internal pure {
        uint256 expectedIsRevocationChecked = 1;
        if (skipClaimRevocationCheck) {
            expectedIsRevocationChecked = 0;
        }
        require(
            isRevocationChecked == expectedIsRevocationChecked,
            "Revocation check should match the query"
        );
    }
}
