// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Payload} from "wallet-contracts-v3/modules/Payload.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ILiFi} from "lifi-contracts/Interfaces/ILiFi.sol";
import {LibSwap} from "lifi-contracts/Libraries/LibSwap.sol";
import {AnypayLiFiFlagDecoder} from "./libraries/AnypayLiFiFlagDecoder.sol";
import {AnypayLiFiInterpreter, AnypayLiFiInfo} from "./libraries/AnypayLiFiInterpreter.sol";
import {AnypayIntentParams} from "./libraries/AnypayIntentParams.sol";
import {ISapient} from "wallet-contracts-v3/modules/interfaces/ISapient.sol";
import {AnypayDecodingStrategy} from "./interfaces/AnypayLiFi.sol";

/**
 * @title AnypayLiFiSapientSigner
 * @author Shun Kakinoki
 * @notice An SapientSigner module for Sequence v3 wallets, designed to facilitate LiFi actions
 *         through the sapient signer module. It validates off-chain attestations to authorize
 *         operations on a specific LiFi Diamond contract. This enables relayers to execute LiFi
 *         swaps/bridges as per user-attested parameters, without direct wallet pre-approval for each transaction.
 */
// contract AnypayLiFiSapientSigner is ISapient {
contract AnypayLiFiSapientSigner is ISapient {
    // -------------------------------------------------------------------------
    // Libraries
    // -------------------------------------------------------------------------

    using Payload for Payload.Decoded;
    using AnypayLiFiFlagDecoder for bytes;
    using AnypayLiFiInterpreter for AnypayLiFiInfo[];
    using AnypayLiFiInterpreter for ILiFi.BridgeData;
    using AnypayIntentParams for AnypayLiFiInfo[];

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    address public immutable TARGET_LIFI_DIAMOND;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error InvalidTargetAddress(address expectedTarget, address actualTarget);
    error InvalidCallsLength();
    error InvalidPayloadKind();
    error InvalidLifiDiamondAddress();
    error InvalidAttestationSigner(address expectedSigner, address actualSigner);
    error InvalidAttestation();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _lifiDiamondAddress) {
        if (_lifiDiamondAddress == address(0)) {
            revert InvalidLifiDiamondAddress();
        }
        TARGET_LIFI_DIAMOND = _lifiDiamondAddress;
    }

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @inheritdoc ISapient
    function recoverSapientSignature(Payload.Decoded calldata payload, bytes calldata encodedSignature)
        external
        view
        returns (bytes32)
    {
        // 1. Validate outer Payload
        if (payload.kind != Payload.KIND_TRANSACTIONS) {
            revert InvalidPayloadKind();
        }

        // 2. Validate inner Payload
        if (payload.calls.length == 0) {
            revert InvalidCallsLength();
        }

        // 3. Verify target address and applicationData matches _lifiCall
        for (uint256 i = 0; i < payload.calls.length; i++) {
            Payload.Call memory call = payload.calls[i];
            if (call.to != TARGET_LIFI_DIAMOND) {
                revert InvalidTargetAddress(TARGET_LIFI_DIAMOND, call.to);
            }
        }

        // 4. Decode the signature
        (
            AnypayLiFiInfo[] memory attestationLifiInfos,
            AnypayDecodingStrategy decodingStrategy,
            bytes memory attestationSignature,
            address attestationSigner
        ) = decodeSignature(encodedSignature);

        // 5. Recover the signer from the attestation signature
        address recoveredAttestationSigner =
            ECDSA.recover(keccak256(abi.encode(payload.hashFor(address(0)))), attestationSignature);

        // 6. Validate the attestation signer
        if (recoveredAttestationSigner != attestationSigner) {
            revert InvalidAttestationSigner(attestationSigner, recoveredAttestationSigner);
        }

        // 7. Initialize structs to store decoded data
        AnypayLiFiInfo[] memory inferredLifiInfos = new AnypayLiFiInfo[](payload.calls.length);

        // 8. Decode BridgeData and SwapData from calldata using the library
        for (uint256 i = 0; i < payload.calls.length; i++) {
            (ILiFi.BridgeData memory bridgeData, LibSwap.SwapData[] memory swapData) =
                payload.calls[i].data.decodeLiFiDataOrRevert(decodingStrategy);

            inferredLifiInfos[i] = bridgeData.getOriginSwapInfo(swapData);
        }

        // 9. Validate the attestations
        if (!inferredLifiInfos.validateLifiInfos(attestationLifiInfos)) {
            revert InvalidAttestation();
        }

        // 10. Hash the lifi intent params
        bytes32 lifiIntentHash = attestationLifiInfos.getAnypayLiFiInfoHash(attestationSigner);

        return lifiIntentHash;
    }

    // -------------------------------------------------------------------------
    // Internal Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Decodes a combined signature into LiFi information and the attestation signature.
     * @dev Assumes _signature is abi.encode(AnypayLiFiInfo[] memory, bytes memory).
     * @param _signature The combined signature bytes.
     * @return _lifiInfos Array of AnypayLiFiInfo structs.
     * @return _decodingStrategy The decoding strategy used.
     * @return _attestationSignature The ECDSA signature for attestation.
     */
    function decodeSignature(bytes calldata _signature)
        public
        pure
        returns (
            AnypayLiFiInfo[] memory _lifiInfos,
            AnypayDecodingStrategy _decodingStrategy,
            bytes memory _attestationSignature,
            address _attestationSigner
        )
    {
        (_lifiInfos, _decodingStrategy, _attestationSignature, _attestationSigner) =
            abi.decode(_signature, (AnypayLiFiInfo[], AnypayDecodingStrategy, bytes, address));
    }
}
