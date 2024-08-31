// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.26;

import {IState} from "../interfaces/IState.sol";
import {IStateWithTimestampGetters} from "../interfaces/IStateWithTimestampGetters.sol";
import {IState} from "../interfaces/IState.sol";
import {IOracleProofValidator} from "../interfaces/IOracleProofValidator.sol";
import {IStateCrossChain} from "../interfaces/IStateCrossChain.sol";

contract StateCrossChain is IStateCrossChain {
    enum DataLocation {
        Storage,
        TransientStorage
    }

    DataLocation constant dataLocation = DataLocation.Storage;

    /// @custom:storage-location erc7201:iden3.storage.StateCrossChain
    struct StateCrossChainStorage {
        mapping(uint256 id => mapping(uint256 state => uint256 replacedAt)) _idToStateReplacedAt;
        mapping(bytes2 idType => mapping(uint256 root => uint256 replacedAt)) _rootToGistRootReplacedAt;
        IOracleProofValidator _oracleProofValidator;
        IStateWithTimestampGetters _state;
    }

    // keccak256(abi.encode(uint256(keccak256("iden3.storage.StateCrossChain")) - 1))
    //  & ~bytes32(uint256(0xff));
    bytes32 private constant StateCrossChainStorageLocation =
        0xfe6de916382846695d2555237dc6c0ef6555f4c949d4ba263e03532600778100;

    function _getStateCrossChainStorage() private pure returns (StateCrossChainStorage storage $) {
        assembly {
            $.slot := StateCrossChainStorageLocation
        }
    }

    constructor(IOracleProofValidator validator, IStateWithTimestampGetters state) {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();
        $._oracleProofValidator = validator;
        $._state = state;
    }

    function processProof(bytes calldata proof) public {
        if (proof.length == 0) {
            return;
        }

        CrossChainProof[] memory proofs = abi.decode(proof, (CrossChainProof[]));

        for (uint256 i = 0; i < proofs.length; i++) {
            if (keccak256(bytes(proofs[i].proofType)) == keccak256(bytes("globalStateProof"))) {
                GlobalStateUpdate memory globalStateUpd = abi.decode(
                    proofs[i].proof,
                    (GlobalStateUpdate)
                );

                _setGistRootInfo(globalStateUpd.globalStateMsg, globalStateUpd.signature);
            } else if (keccak256(bytes(proofs[i].proofType)) == keccak256(bytes("stateProof"))) {
                IdentityStateUpdate memory idStateUpd = abi.decode(
                    proofs[i].proof,
                    (IdentityStateUpdate)
                );

                _setStateInfo(idStateUpd.idStateMsg, idStateUpd.signature);
            } else {
                revert("Unknown proof type");
            }
        }
    }

    function getStateReplacedAt(
        uint256 id,
        uint256 state
    ) external view returns (uint256 replacedAt) {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();
        replacedAt = $._idToStateReplacedAt[id][state];
        if (replacedAt == 0) {
            replacedAt = $._state.getStateReplacedAt(id, state);
        }
    }

    function getGistRootReplacedAt(
        bytes2 idType,
        uint256 root
    ) external view returns (uint256 replacedAt) {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();
        replacedAt = $._rootToGistRootReplacedAt[idType][root];
        if (replacedAt == 0) {
            replacedAt = $._state.getGistRootReplacedAt(idType, root);
        }
    }

    function getIdTypeIfSupported(uint256 id) external view returns (bytes2 idType) {
        return _getStateCrossChainStorage()._state.getIdTypeIfSupported(id);
    }

    function _setStateInfo(IdentityStateMessage memory message, bytes memory signature) internal {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();

        require(
            $._oracleProofValidator.verifyIdentityState(message, signature),
            "Identity state proof is not valid"
        );

        uint256 replacedAt = message.replacedAtTimestamp == 0
            ? message.timestamp
            : message.replacedAtTimestamp;
        require(replacedAt != 0, "ReplacedAt cannot be 0");

        $._idToStateReplacedAt[message.id][message.state] = replacedAt;
    }

    function _setGistRootInfo(GlobalStateMessage memory message, bytes memory signature) internal {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();

        require(
            $._oracleProofValidator.verifyGlobalState(message, signature),
            "Global state proof is not valid"
        );

        uint256 replacedAt = message.replacedAtTimestamp == 0
            ? message.timestamp
            : message.replacedAtTimestamp;
        require(replacedAt != 0, "ReplacedAt cannot be 0");

        $._rootToGistRootReplacedAt[message.idType][message.root] = replacedAt;
    }

    function getStateReplacedAt2(
        uint256 id,
        uint256 state
    ) public view returns (uint256 replacedAt) {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();
        mapping(uint256 => mapping(uint256 => uint256)) storage map = $._idToStateReplacedAt;
        bytes32 slot;
        assembly {
            slot := map.slot
        }

        bytes32 idMapLocation = _getMappingValueLocation(slot, bytes32(id));
        bytes32 valueLocation = _getMappingValueLocation(idMapLocation, bytes32(state));
        replacedAt = uint256(_getSlotValue(valueLocation));
    }

    function getGistRootReplacedAt2(
        bytes2 idType,
        uint256 root
    ) public view returns (uint256 replacedAt) {
        StateCrossChainStorage storage $ = _getStateCrossChainStorage();
        mapping(bytes2 => mapping(uint256 => uint256)) storage map = $._rootToGistRootReplacedAt;
        bytes32 slot;
        assembly {
            slot := map.slot
        }

        bytes32 idTypeMapLocation = _getMappingValueLocation(slot, bytes32(idType));
        bytes32 valueLocation = _getMappingValueLocation(idTypeMapLocation, bytes32(root));
        replacedAt = uint256(_getSlotValue(valueLocation));
    }

    function _getMappingValueLocation(
        bytes32 slot,
        bytes32 key
    ) internal view returns (bytes32 keyLocation) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, key)
            mstore(add(ptr, 0x20), slot)
            keyLocation := keccak256(ptr, 0x40)
        }
    }

    function _getSlotValue(bytes32 slot) internal view returns (bytes32 value) {
        if (dataLocation == DataLocation.Storage) {
            assembly {
                value := sload(slot)
            }
        } else if (dataLocation == DataLocation.TransientStorage) {
            assembly {
                value := tload(slot)
            }
        } else {
            revert("Invalid data location");
        }
    }
}
