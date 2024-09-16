// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {ZKPVerifierBase} from "../verifiers/ZKPVerifierBase.sol";
import {ICircuitValidator} from "../interfaces/ICircuitValidator.sol";
import {SpongePoseidon} from "./Poseidon.sol";

library VerifierLib {
    function writeProofResults(
        ZKPVerifierBase.ZKPVerifierStorage storage self,
        address sender,
        uint64 requestId,
        ICircuitValidator.Signal[] memory signals
    ) public {
        ZKPVerifierBase.Proof storage proof = self._proofs[sender][requestId];
        for (uint256 i = 0; i < signals.length; i++) {
            proof.storageFields[signals[i].name] = signals[i].value;
        }

        proof.isVerified = true;
        proof.validatorVersion = self._requests[requestId].validator.version();
        proof.blockNumber = block.number;
        proof.blockTimestamp = block.timestamp;
    }

    function writeMetadata(
        ZKPVerifierBase.ZKPVerifierStorage storage self,
        address sender,
        bytes memory metadata,
        uint64 requestId
    ) public {
        ZKPVerifierBase.Metadata[] memory meta = abi.decode(metadata, (ZKPVerifierBase.Metadata[]));

        ZKPVerifierBase.Proof storage proof = self._proofs[sender][requestId];
        for (uint256 j = 0; j < meta.length; j++) {
            uint256 hash = SpongePoseidon.hashBytes(meta[j].value);
            require(proof.storageFields[meta[j].key] == hash, "Invalid metadata hash");
            proof.metadata[meta[j].key] = meta[j].value;
        }
    }
}
