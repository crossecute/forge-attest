// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, SafeTxLib} from "./SafeTx.sol";

/// @title SafeTxHashTest
/// @notice Standalone unit tests for forge-attest's Solidity hash derivation.
///         Everything here runs from checked-in fixtures with `forge test`. No
///         network, no env vars, no cloning. The pinned hashes are the values
///         `lib/derive.sh` computes with `cast` from the same fixtures, so a
///         divergence between the two implementations fails the build.
contract SafeTxHashTest {
    using SafeTxLib for SafeTxLib.SafeTx;

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant SAFE = 0x111CEEee040739fD91D29C34C33E6B3E112F2177;
    uint256 internal constant NONCE = 42;

    function _binding() internal pure returns (SafeTxLib.Binding memory b) {
        b.safe = SAFE;
        b.nonce = NONCE;
    }

    function _read(string memory name) internal view returns (string memory) {
        return vm.readFile(string.concat("test/fixtures/", name));
    }

    function _assertEq(bytes32 got, bytes32 want, string memory what) internal pure {
        require(got == want, string.concat(what, ": got ", vm.toString(got), " want ", vm.toString(want)));
    }

    // ------------------------------------------------------------- EIP-712 constants

    /// The type hashes are the foundation of every other assertion here; pin them
    /// so a typo in a type string can never silently move every hash at once.
    function test_TypeHashesAreCanonical() external pure {
        _assertEq(
            SafeTxLib.DOMAIN_TYPEHASH,
            0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218,
            "DOMAIN_TYPEHASH"
        );
        _assertEq(
            SafeTxLib.SAFE_TX_TYPEHASH,
            0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8,
            "SAFE_TX_TYPEHASH"
        );
    }

    function test_VersionGate() external pure {
        require(SafeTxLib.atLeast130("1.3.0"), "1.3.0");
        require(SafeTxLib.atLeast130("1.4.1"), "1.4.1");
        require(SafeTxLib.atLeast130("2.0.0"), "2.0.0");
        require(!SafeTxLib.atLeast130("1.2.0"), "1.2.0");
        require(!SafeTxLib.atLeast130("1.1.1"), "1.1.1");
        require(!SafeTxLib.atLeast130("0.1.0"), "0.1.0");
    }

    // -------------------------------------------------- format 1: canonical SafeTx

    function test_CanonicalSafeTx_MatchesPinnedHash() external view {
        SafeTxLib.SafeTx memory t = SafeTxLib.readCanonical(_read("safe-tx-single.json"));

        require(t.safe == SAFE, "safe");
        require(t.chainId == 1, "chainId");
        require(t.nonce == 42, "nonce");
        require(t.operation == 0, "operation");
        require(t.data.length == 68, "data length");

        _assertEq(t.hash(), 0xd0e33f3b88aceb5122db6ad935c1d709c7602f8ed92fc6b27bdd507902bdf534, "canonical safeTxHash");
    }

    // ------------------------------------ format 2: Transaction Builder batch (Frax)

    /// The real `SafeTxHelper`-generated artifact from
    /// frax-oft-upgradeable: six `upgradeAndCall` proxy admin calls on Optimism.
    function test_FraxBatch_MatchesPinnedHash() external view {
        string memory json = _read("tx-builder-frax-optimism.json");

        SafeTxLib.InnerTx[] memory inner = SafeTxLib.readBatch(json);
        require(inner.length == 6, "inner count");
        require(SafeTxLib.readChainId(json) == 10, "chainId");
        for (uint256 i = 0; i < inner.length; i++) {
            require(inner[i].to == 0x223a681fc5c5522c85C96157c0efA18cd6c5405c, "inner to");
            require(inner[i].value == 0, "inner value");
            require(inner[i].operation == 0, "inner operation");
            require(inner[i].data.length == 164, "inner data length");
        }

        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(json, _binding());

        // >1 transaction, so it is signed as a delegatecall into MultiSendCallOnly.
        require(t.to == SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0, "to == MultiSendCallOnly");
        require(t.operation == 1, "operation == DELEGATECALL");
        require(t.value == 0, "value");
        require(t.chainId == 10, "chainId");
        require(bytes4(t.data) == bytes4(0x8d80ff0a), "multiSend(bytes) selector");

        _assertEq(t.hash(), 0xa55af81f3e8e946ba3989ba04fe1fa0685a104114c479e05f0367bba8c712680, "frax batch safeTxHash");
    }

    /// The whole point of normalising: a batch re-generated on another day carries
    /// a different `createdAt` and `meta`, and producers vary in key order, address
    /// checksum casing, hex casing, string-vs-number scalars and whether they emit
    /// a default `operation`. None of that may move the hash the owners sign.
    function test_VolatileMetadataDoesNotAffectHash() external view {
        bytes32 original = SafeTxLib.readAny(_read("tx-builder-frax-optimism.json"), _binding()).hash();
        bytes32 restamped = SafeTxLib.readAny(_read("tx-builder-frax-optimism-restamped.json"), _binding()).hash();
        _assertEq(restamped, original, "restamped batch");
    }

    /// ...but changing anything the Safe actually executes must move it.
    function test_TamperedBatchChangesHash() external view {
        string memory json = _read("tx-builder-frax-optimism.json");
        SafeTxLib.Binding memory b = _binding();
        bytes32 original = SafeTxLib.readAny(json, b).hash();

        SafeTxLib.InnerTx[] memory inner = SafeTxLib.readBatch(json);

        // (a) redirect one inner call
        SafeTxLib.InnerTx[] memory tampered = _copy(inner);
        tampered[3].to = address(0xBAD);
        require(SafeTxLib.toSafeTx(tampered, b, 10).hash() != original, "inner `to` not detected");

        // (b) flip one calldata byte
        tampered = _copy(inner);
        tampered[0].data[100] = bytes1(uint8(tampered[0].data[100]) ^ 0x01);
        require(SafeTxLib.toSafeTx(tampered, b, 10).hash() != original, "inner data not detected");

        // (c) drop a transaction from the batch
        SafeTxLib.InnerTx[] memory shorter = new SafeTxLib.InnerTx[](inner.length - 1);
        for (uint256 i = 0; i < shorter.length; i++) {
            shorter[i] = inner[i];
        }
        require(SafeTxLib.toSafeTx(shorter, b, 10).hash() != original, "dropped transaction not detected");

        // (d) reorder the batch
        SafeTxLib.InnerTx[] memory swapped = _copy(inner);
        (swapped[0], swapped[1]) = (swapped[1], swapped[0]);
        require(SafeTxLib.toSafeTx(swapped, b, 10).hash() != original, "reordering not detected");

        // (e) bump the nonce
        SafeTxLib.Binding memory nextNonce = b;
        nextNonce.nonce = NONCE + 1;
        require(SafeTxLib.toSafeTx(inner, nextNonce, 10).hash() != original, "nonce not detected");

        // (f) same batch, different chain
        require(SafeTxLib.toSafeTx(inner, b, 8453).hash() != original, "chainId not detected");

        // (g) same batch, different Safe
        SafeTxLib.Binding memory otherSafe = b;
        otherSafe.safe = address(0xB0B);
        require(SafeTxLib.toSafeTx(inner, otherSafe, 10).hash() != original, "safe address not detected");
    }

    // ------------------------------------------------------- MultiSend encoding

    /// Golden bytes for the packed MultiSend layout: `operation | to | value |
    /// data.length | data`, tightly packed with no padding between entries.
    function test_MultiSendPayloadLayout() external pure {
        SafeTxLib.InnerTx[] memory txs = new SafeTxLib.InnerTx[](2);
        txs[0] = SafeTxLib.InnerTx({to: address(0xAAAA), value: 0, data: hex"deadbeef", operation: 0});
        txs[1] = SafeTxLib.InnerTx({to: address(0xBBBB), value: 1 ether, data: "", operation: 0});

        bytes memory payload = SafeTxLib.encodeMultiSendPayload(txs);

        _assertEq(
            keccak256(payload),
            keccak256(
                abi.encodePacked(
                    hex"00",
                    hex"000000000000000000000000000000000000aaaa",
                    uint256(0),
                    uint256(4),
                    hex"deadbeef",
                    hex"00",
                    hex"000000000000000000000000000000000000bbbb",
                    uint256(1 ether),
                    uint256(0)
                )
            ),
            "packed payload"
        );
        require(payload.length == (1 + 20 + 32 + 32 + 4) + (1 + 20 + 32 + 32), "payload length");

        bytes memory cd = SafeTxLib.encodeMultiSendCalldata(txs);
        require(bytes4(cd) == bytes4(0x8d80ff0a), "selector");
        require(keccak256(cd) == keccak256(abi.encodeWithSignature("multiSend(bytes)", payload)), "abi wrapper");
    }

    function test_MultiSendPayloadIsOrderSensitive() external pure {
        SafeTxLib.InnerTx[] memory txs = new SafeTxLib.InnerTx[](2);
        txs[0] = SafeTxLib.InnerTx({to: address(0xAAAA), value: 0, data: hex"1122", operation: 0});
        txs[1] = SafeTxLib.InnerTx({to: address(0xBBBB), value: 0, data: hex"3344", operation: 0});
        bytes memory forward = SafeTxLib.encodeMultiSendPayload(txs);
        (txs[0], txs[1]) = (txs[1], txs[0]);
        require(keccak256(forward) != keccak256(SafeTxLib.encodeMultiSendPayload(txs)), "order-insensitive");
    }

    /// Adjacent entries must not be able to masquerade as one another: a payload
    /// is only unambiguous because each entry declares its own data length.
    function test_MultiSendPayloadIsUnambiguous() external pure {
        SafeTxLib.InnerTx[] memory a = new SafeTxLib.InnerTx[](1);
        a[0] = SafeTxLib.InnerTx({to: address(0xAAAA), value: 0, data: hex"00112233", operation: 0});

        SafeTxLib.InnerTx[] memory b = new SafeTxLib.InnerTx[](1);
        b[0] = SafeTxLib.InnerTx({to: address(0xAAAA), value: 0, data: hex"0011223300", operation: 0});

        require(
            keccak256(SafeTxLib.encodeMultiSendPayload(a)) != keccak256(SafeTxLib.encodeMultiSendPayload(b)),
            "length not committed"
        );
    }

    // ------------------------------------------------------------ batch wrapping

    /// A single-transaction batch is sent to its target directly, the same thing
    /// Safe{Wallet} does, so it must hash like a plain SafeTx, not a MultiSend.
    function test_SingleTransactionBatchIsNotWrapped() external view {
        string memory json = _read("tx-builder-single.json");
        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(json, _binding());

        require(t.to == 0x000000000000000000000000000000000000dEaD, "to");
        require(t.value == 1 ether, "value");
        require(t.data.length == 0, "null data -> empty calldata");
        require(t.operation == 0, "operation");
        require(t.chainId == 1, "chainId");

        _assertEq(t.hash(), 0x38f6021556163a7ec5d95142772e3143accac2c360f2e1ec0ceb4a63c1b41c3f, "single-tx batch");
    }

    function test_ForceMultiSendWrapsASingleTransaction() external view {
        SafeTxLib.Binding memory b = _binding();
        b.forceMultiSend = true;

        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(_read("tx-builder-single.json"), b);
        require(t.to == SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0, "to");
        require(t.operation == 1, "operation");

        _assertEq(t.hash(), 0x1e205bd4492f165a9784185d6f89f15bfdad13043af1da9721e8e694908ee1dc, "forced multisend");
    }

    /// The version -> MultiSend mapping must cover exactly the versions
    /// `lib/normalize.sh` covers. If one side maps a version the other doesn't,
    /// the two derivations pick different `to` addresses and silently disagree.
    /// That is the one failure mode this whole design exists to prevent.
    function test_DefaultMultiSendMapsOnlyKnownVersions() external {
        require(SafeTxLib.defaultMultiSend("1.3.0", 1) == SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0, "1.3.0");
        require(SafeTxLib.defaultMultiSend("1.3.1", 1) == SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0, "1.3.1");
        require(SafeTxLib.defaultMultiSend("1.4.1", 1) == SafeTxLib.MULTI_SEND_CALL_ONLY_1_4_1, "1.4.1");
        require(SafeTxLib.defaultMultiSend("1.5.0", 1) == SafeTxLib.MULTI_SEND_CALL_ONLY_1_5_0, "1.5.0");

        // Unknown versions must be refused, not guessed at.
        string[3] memory unknown = ["1.6.0", "2.0.0", "1.9.9"];
        for (uint256 i = 0; i < unknown.length; i++) {
            (bool ok,) = address(this).call(abi.encodeCall(this.defaultMultiSendExternal, (unknown[i], uint256(1))));
            require(!ok, string.concat("should refuse ", unknown[i]));
        }
    }

    /// The canonical MultiSendCallOnly is not universal: on some chains it is not
    /// deployed, and on the zkSync-family chains a different-bytecode deployment is
    /// the one Safe{Wallet} uses. Defaulting there would produce a `to` the Safe
    /// never calls, a wrong hash that still looks authoritative.
    function test_RefusesCanonicalMultiSendOnDivergentChains() external {
        (bool ok, bytes memory err) = address(this).call(
            abi.encodeCall(this.readAnyExternal, (_read("tx-builder-zksync-era.json"), _binding()))
        );
        require(!ok, "zkSync Era accepted the canonical address");
        require(_contains(err, "does not use the canonical MultiSendCallOnly"), "wrong revert");

        // Naming the address explicitly is still fine. The guard is on guessing.
        SafeTxLib.Binding memory b = _binding();
        b.multiSend = 0xf220D3b4DFb23C4ade8C88E526C1353AbAcbC38F; // zkSync 1.3.0
        require(SafeTxLib.readAny(_read("tx-builder-zksync-era.json"), b).to == b.multiSend, "explicit rejected");
    }

    /// Chains that do use the canonical deployment must be unaffected.
    function test_CanonicalChainsAreUnaffected() external view {
        require(
            SafeTxLib.readAny(_read("tx-builder-frax-optimism.json"), _binding()).to
                == SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0,
            "Optimism should still default"
        );
        require(SafeTxLib.defaultMultiSend("1.5.0", 324) == SafeTxLib.MULTI_SEND_CALL_ONLY_1_5_0, "1.5.0 has no exceptions");
    }

    /// An unknown version is still attestable. The caller just has to name the
    /// address rather than have one invented for them.
    function test_UnknownVersionWorksWithExplicitMultiSend() external view {
        SafeTxLib.Binding memory b = _binding();
        b.safeVersion = "1.9.9";
        b.multiSend = SafeTxLib.MULTI_SEND_CALL_ONLY_1_4_1;

        require(SafeTxLib.readAny(_read("tx-builder-frax-optimism.json"), b).to == SafeTxLib.MULTI_SEND_CALL_ONLY_1_4_1, "explicit");
    }

    /// Gas/refund fields are hash inputs that no batch format carries. If the
    /// binding drops them, a non-zero config diverges from the bash derivation.
    function test_GasFieldsReachTheHash() external view {
        string memory json = _read("tx-builder-frax-optimism.json");
        bytes32 allZero = SafeTxLib.readAny(json, _binding()).hash();

        SafeTxLib.Binding memory b = _binding();
        b.gasPrice = 1000;
        b.safeTxGas = 50000;

        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(json, b);
        require(t.gasPrice == 1000 && t.safeTxGas == 50000, "gas fields dropped");
        require(t.hash() != allZero, "gas fields not in the hash");

        // Matches what lib/derive.sh computes for the same canonical SafeTx.
        _assertEq(t.hash(), 0x99c89e49492f5d8c82122f2720c9d5b6c34939b6ce24480b471c617b35a396f4, "gas-bearing hash");

        SafeTxLib.Binding memory refunds = _binding();
        refunds.gasToken = 0x000000000000000000000000000000000000bEEF;
        refunds.refundReceiver = 0x000000000000000000000000000000000000cafE;
        require(SafeTxLib.readAny(json, refunds).hash() != allZero, "refund fields not in the hash");
    }

    /// `data` that is present but not valid hex is a producer bug. Treating it as
    /// empty calldata would attest a transaction nobody wrote.
    function test_RejectsMalformedHexData() external {
        (bool ok, bytes memory err) =
            address(this).call(abi.encodeCall(this.readBatchExternal, (_read("tx-builder-bad-hex.json"))));
        require(!ok, "malformed hex was accepted");
        require(!_contains(err, "should never happen"), "sanity");
    }

    /// ...while an explicit null still means "no calldata", as the Safe UI emits
    /// for a plain value transfer.
    function test_NullDataIsStillEmptyCalldata() external view {
        SafeTxLib.InnerTx[] memory inner = SafeTxLib.readBatch(_read("tx-builder-single.json"));
        require(inner[0].data.length == 0, "null should be empty");
    }

    /// Safe 1.4.x batches go through a different MultiSendCallOnly deployment, so
    /// the same batch on the same Safe signs as a different transaction.
    function test_SafeVersionSelectsMultiSendDeployment() external view {
        SafeTxLib.Binding memory b = _binding();
        b.safeVersion = "1.4.1";

        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(_read("tx-builder-frax-optimism.json"), b);
        require(t.to == SafeTxLib.MULTI_SEND_CALL_ONLY_1_4_1, "1.4.1 MultiSendCallOnly");
        require(t.hash() != SafeTxLib.readAny(_read("tx-builder-frax-optimism.json"), _binding()).hash(), "same hash");
    }

    // ------------------------------------------------- a batch that binds itself

    function test_BatchSafeBindings() external {
        string[2] memory fixtures = ["tx-builder-self-binding.json", "tx-builder-etherfi-binding.json"];
        for (uint256 i = 0; i < fixtures.length; i++) {
            string memory json = _read(fixtures[i]);
            require(SafeTxLib.readSafeAddress(json) == SAFE, "declared safe");
            SafeTxLib.Binding memory b;
            b.nonce = NONCE;
            SafeTxLib.SafeTx memory t = SafeTxLib.readAny(json, b);
            require(t.safe == SAFE, "safe from file");
            require(t.chainId == 1, "chainId");
            bytes32 expected = 0x451bf409acadd38b8aecde55d6fd4b4f2c0689465525db81f10ec6426a376d83;
            _assertEq(t.hash(), expected, "self-binding batch");
            _assertEq(SafeTxLib.readAny(json, _binding()).hash(), expected, "agreeing config");
            b.safe = address(0xB0B);
            (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.readAnyExternal, (json, b)));
            require(!ok && _contains(err, "safe address mismatch"), "expected config mismatch");
        }
    }

    function test_BatchSafeDeclarationAgreement() external {
        string memory safe = vm.toString(SAFE);
        string memory other = vm.toString(address(0xB0B));
        for (uint256 i = 0; i < 4; i++) {
            string memory json = string.concat(
                '{"chainId":"1","safe":"', i == 0 ? other : safe,
                '","safeAddress":"', i == 1 ? other : safe,
                '","meta":{"createdFromSafeAddress":"', i == 2 ? other : safe,
                '"},"transactions":[{"to":"0x0000000000000000000000000000000000000b0b"}]}'
            );
            SafeTxLib.Binding memory b;
            b.nonce = NONCE;
            if (i == 3) {
                require(SafeTxLib.readAny(json, b).safe == SAFE, "agreeing declarations");
            } else {
                (bool ok, bytes memory err) = address(this).call(abi.encodeCall(this.readAnyExternal, (json, b)));
                require(!ok && _contains(err, "safe address mismatch"), "expected declaration mismatch");
            }
        }
    }

    /// Files with no such declaration keep working exactly as before.
    function test_UndeclaredSafeStillComesFromConfig() external view {
        string memory json = _read("tx-builder-frax-optimism.json");
        require(SafeTxLib.readSafeAddress(json) == address(0), "nothing declared");
        require(SafeTxLib.readAny(json, _binding()).safe == SAFE, "safe from config");
    }

    // ------------------------------------------------------- format 3: bare array

    function test_BareTransactionArray() external view {
        string memory json = _read("tx-array.json");
        require(SafeTxLib.readChainId(json) == 0, "a bare array carries no chainId");

        SafeTxLib.InnerTx[] memory inner = SafeTxLib.readBatch(json);
        require(inner.length == 2, "count");
        require(inner[0].data.length == 68, "erc20 transfer calldata");
        require(inner[1].value == 1 ether, "value from string");
        require(inner[1].data.length == 0, "0x -> empty");

        SafeTxLib.Binding memory b = _binding();
        b.chainId = 1; // must come from config
        _assertEq(SafeTxLib.toSafeTx(inner, b, 0).hash(), 0xb9bb6f19acb8d7459a17726181922c4e66223f5c7b6b0d17e120e11e8a13f774, "bare array");
    }

    // ------------------------------------------------------- format 4: plain call

    /// The call inside `safe-tx-single.json`, bound to that file's Safe, nonce
    /// and chain, is the same transaction and must hash to the same value.
    function test_PlainCall_MatchesPinnedHash() external view {
        string memory json = _read("call.json");
        require(!SafeTxLib.bindsSafeTx(json), "a call binds no SafeTx field");

        SafeTxLib.Binding memory b = _binding();
        b.chainId = 1; // must come from config
        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(json, b);

        require(t.to == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "sent directly, not wrapped");
        require(t.operation == 0, "operation defaults to CALL");
        _assertEq(t.hash(), 0xd0e33f3b88aceb5122db6ad935c1d709c7602f8ed92fc6b27bdd507902bdf534, "plain call");
        _assertEq(t.hash(), SafeTxLib.readCanonical(_read("safe-tx-single.json")).hash(), "call vs complete SafeTx");
    }

    function test_PlainCallRequiresChainIdFromConfig() external {
        (bool ok, bytes memory err) =
            address(this).call(abi.encodeCall(this.readAnyExternal, (_read("call.json"), _binding())));
        require(!ok, "expected revert");
        require(_contains(err, "no chainId"), "wrong revert");
    }

    /// A call may be a delegatecall, as a one-entry array may, and is signed as one.
    function test_PlainCallKeepsItsOperation() external view {
        SafeTxLib.Binding memory b = _binding();
        b.chainId = 1;
        SafeTxLib.SafeTx memory t =
            SafeTxLib.readAny('{"to":"0x000000000000000000000000000000000000dEaD","operation":1}', b);
        require(t.operation == 1 && t.to == address(0xdEaD) && t.data.length == 0, "delegatecall");
    }

    function test_RejectsInvalidOperationsAcrossFormats() external {
        uint256[3] memory invalid = [uint256(2), 256, type(uint256).max];
        for (uint256 i = 0; i < invalid.length; i++) {
            for (uint256 quoted = 0; quoted < 2; quoted++) {
                string[4] memory formats = _operationFormats(invalid[i], quoted == 1);
                for (uint256 j = 0; j < formats.length; j++) {
                    SafeTxLib.Binding memory b = _binding();
                    b.chainId = 1;
                    (bool ok, bytes memory err) =
                        address(this).call(abi.encodeCall(this.readAnyExternal, (formats[j], b)));
                    require(!ok, "accepted invalid operation");
                    require(_contains(err, "operation must be 0 or 1"), "wrong revert");
                }
            }
        }
    }

    function test_ValidOperationsAgreeAcrossFormats() external view {
        SafeTxLib.Binding memory b = _binding();
        b.chainId = 1;
        for (uint256 operation = 0; operation < 2; operation++) {
            string[4] memory numeric = _operationFormats(operation, false);
            bytes32 expected = SafeTxLib.readAny(numeric[0], b).hash();
            for (uint256 quoted = 0; quoted < 2; quoted++) {
                string[4] memory formats = _operationFormats(operation, quoted == 1);
                for (uint256 j = 0; j < formats.length; j++) {
                    SafeTxLib.SafeTx memory t = SafeTxLib.readAny(formats[j], b);
                    require(t.operation == operation, "operation changed");
                    _assertEq(t.hash(), expected, "operation across formats");
                }
            }
        }
    }

    function _operationFormats(uint256 operation, bool quoted) private pure returns (string[4] memory formats) {
        string memory value = vm.toString(operation);
        if (quoted) value = string.concat('"', value, '"');
        string memory fields = string.concat(
            '"to":"0x000000000000000000000000000000000000dEaD","operation":', value
        );
        formats[0] = string.concat('{', fields, '}');
        formats[1] = string.concat('[', formats[0], ']');
        formats[2] = string.concat('{"transactions":', formats[1], '}');
        formats[3] = string.concat(
            '{', fields, ',"safe":"', vm.toString(SAFE),
            '","chainId":1,"nonce":42,"value":0,"safeTxGas":0,"baseGas":0,"gasPrice":0,',
            '"gasToken":"0x0000000000000000000000000000000000000000",',
            '"refundReceiver":"0x0000000000000000000000000000000000000000"}'
        );
    }

    /// An object with any SafeTx field is a SafeTx, and a partial one is refused
    /// rather than completed from the binding.
    function test_PartialSafeTxIsNotCompletedFromConfig() external {
        SafeTxLib.Binding memory b = _binding();
        b.chainId = 1;
        string memory partialTx = '{"to":"0x000000000000000000000000000000000000dEaD","nonce":"42"}';
        (bool ok,) = address(this).call(abi.encodeCall(this.readAnyExternal, (partialTx, b)));
        require(!ok, "a partial SafeTx was completed");
    }

    // --------------------------------------------------------------- guard rails

    /// A UI-exported batch may describe a call as an ABI method plus inputs with a
    /// null `data`. Encoding that needs the target ABI, so refuse rather than
    /// attest a transaction whose calldata we silently invented.
    function test_RejectsContractMethodWithoutData() external {
        (bool ok, bytes memory err) =
            address(this).call(abi.encodeCall(this.readBatchExternal, (_read("tx-builder-contract-method.json"))));
        require(!ok, "expected revert");
        require(_contains(err, "contractMethod without encoded data"), "wrong revert");
    }

    /// MultiSendCallOnly reverts on inner delegatecalls, so a batch containing one
    /// could never execute. Signing it would attest an unusable transaction.
    function test_RejectsInnerDelegateCallUnderCallOnly() external {
        SafeTxLib.InnerTx[] memory inner = SafeTxLib.readBatch(_read("tx-builder-delegatecall.json"));
        require(inner[1].operation == 1, "fixture should contain a delegatecall");

        (bool ok, bytes memory err) =
            address(this).call(abi.encodeCall(this.toSafeTxExternal, (inner, _binding(), 1)));
        require(!ok, "expected revert");
        require(_contains(err, "rejected by MultiSendCallOnly"), "wrong revert");

        // The plain MultiSend does allow them, so an explicit override works.
        SafeTxLib.Binding memory b = _binding();
        b.multiSend = 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761; // MultiSend 1.3.0
        require(SafeTxLib.toSafeTx(inner, b, 1).operation == 1, "override rejected");
    }

    /// Every MultiSendCallOnly deployment rejects inner DELEGATECALLs, not just the
    /// 1.3.0 canonical one. Missing an address from that list silently re-allows a
    /// batch that could never execute.
    function test_RejectsInnerDelegateCallUnderEveryCallOnlyDeployment() external {
        SafeTxLib.InnerTx[] memory inner = SafeTxLib.readBatch(_read("tx-builder-delegatecall.json"));

        address[6] memory callOnly = [
            SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0,
            SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0_EIP155,
            SafeTxLib.MULTI_SEND_CALL_ONLY_1_3_0_ZKSYNC,
            SafeTxLib.MULTI_SEND_CALL_ONLY_1_4_1,
            SafeTxLib.MULTI_SEND_CALL_ONLY_1_4_1_ZKSYNC,
            SafeTxLib.MULTI_SEND_CALL_ONLY_1_5_0
        ];

        for (uint256 i = 0; i < callOnly.length; i++) {
            SafeTxLib.Binding memory b = _binding();
            b.multiSend = callOnly[i];
            (bool ok,) = address(this).call(abi.encodeCall(this.toSafeTxExternal, (inner, b, 1)));
            require(!ok, string.concat("accepted a delegatecall under ", vm.toString(callOnly[i])));
        }
    }

    /// The 1.5.0 default in particular, the version added alongside this guard.
    function test_RejectsInnerDelegateCallUnderThe150Default() external {
        SafeTxLib.Binding memory b = _binding();
        b.safeVersion = "1.5.0";
        (bool ok, bytes memory err) =
            address(this).call(abi.encodeCall(this.readAnyExternal, (_read("tx-builder-delegatecall.json"), b)));
        require(!ok, "1.5.0 default accepted a delegatecall");
        require(_contains(err, "rejected by MultiSendCallOnly"), "wrong revert");
    }

    function test_RejectsLegacySafeVersion() external {
        SafeTxLib.SafeTx memory t = SafeTxLib.readCanonical(_read("safe-tx-single.json"));
        t.safeVersion = "1.2.0";
        (bool ok,) = address(this).call(abi.encodeCall(this.hashExternal, (t)));
        require(!ok, "Safe < 1.3.0 must not be derived offline");
    }

    function test_RejectsEmptyBatch() external {
        SafeTxLib.InnerTx[] memory none = new SafeTxLib.InnerTx[](0);
        (bool ok,) = address(this).call(abi.encodeCall(this.toSafeTxExternal, (none, _binding(), 1)));
        require(!ok, "expected revert on empty batch");
    }

    // ------------------------------------------------------------- nested Safes

    address internal constant PARENT = SAFE;
    address internal constant CHILD = 0x2222AA22bb22CC22dd22ee22fF220022110022FF;
    bytes32 internal constant PARENT_HASH = 0x6dadc73a833c7960871e229102e841631c21a2c4804ab190432fec57ebacce57;

    /// A Safe that owns another Safe approves on-chain instead of signing. The
    /// approval is fully determined by its inputs, so it is constructed, not read.
    function test_ApprovalTxIsFullyDetermined() external pure {
        SafeTxLib.SafeTx memory t = SafeTxLib.approvalTx(PARENT, PARENT_HASH, CHILD, 7, 1, "1.3.0");

        require(t.safe == CHILD, "signed by the child");
        require(t.to == PARENT, "sent to the parent");
        require(t.value == 0 && t.operation == 0, "plain zero-value CALL");
        require(t.safeTxGas == 0 && t.baseGas == 0 && t.gasPrice == 0, "no gas refunds");
        require(t.data.length == 36, "selector + one word");
        require(bytes4(t.data) == SafeTxLib.APPROVE_HASH_SELECTOR, "approveHash selector");
        require(SafeTxLib.approvedHashIn(_one(t), PARENT) == PARENT_HASH, "commits to the parent hash");

        // Matches lib/derive.sh over the same constructed transaction.
        _assertEq(t.hash(), 0x73c63c06ac272032873f01cc1a80394bda911d061501699ad598f56d03313105, "approval hash");
    }

    /// Everything the approval binds must move its hash. Otherwise a signer could
    /// be shown one approval and have another executed.
    function test_ApprovalHashBindsEveryInput() external pure {
        bytes32 base = SafeTxLib.approvalTx(PARENT, PARENT_HASH, CHILD, 7, 1, "1.3.0").hash();

        require(SafeTxLib.approvalTx(PARENT, bytes32(uint256(PARENT_HASH) ^ 1), CHILD, 7, 1, "1.3.0").hash() != base, "parent hash");
        require(SafeTxLib.approvalTx(PARENT, PARENT_HASH, CHILD, 8, 1, "1.3.0").hash() != base, "child nonce");
        require(SafeTxLib.approvalTx(PARENT, PARENT_HASH, address(0xB0B), 7, 1, "1.3.0").hash() != base, "child safe");
        require(SafeTxLib.approvalTx(address(0xB0B), PARENT_HASH, CHILD, 7, 1, "1.3.0").hash() != base, "parent safe");
        require(SafeTxLib.approvalTx(PARENT, PARENT_HASH, CHILD, 7, 8453, "1.3.0").hash() != base, "chainId");
    }

    function test_ApprovalTxRejectsNonsense() external {
        (bool a,) = address(this).call(abi.encodeCall(this.approvalTxExternal, (PARENT, PARENT_HASH, PARENT, 7, 1)));
        require(!a, "a Safe cannot approve on itself");
        (bool b,) = address(this).call(abi.encodeCall(this.approvalTxExternal, (address(0), PARENT_HASH, CHILD, 7, 1)));
        require(!b, "no parent Safe");
        (bool c,) = address(this).call(abi.encodeCall(this.approvalTxExternal, (PARENT, PARENT_HASH, CHILD, 7, 0)));
        require(!c, "no chainId");
    }

    // ------------------------------------------- the preimage-suffix approval

    address internal constant RC_CHILD = 0xb291232F480F41c75802C4a60F1D2AC03404Afef;

    /// The approval Safe 0xb291…Afef executed at nonce 205 on Ethereum: `approveHash`
    /// followed by the Risk Council transaction at nonce 447.
    function test_PreimageApprovalEqualsTheExecutedChildTx() external view {
        SafeTxLib.SafeTx memory parent = SafeTxLib.readCanonical(_read("nested-preimage-parent.json"));
        bytes32 parentHash = parent.hash();
        _assertEq(parentHash, 0x0ea9a8fed74bc267e88a5de190ca88a3c63b5963784f50176bfd0f4fb523f8e4, "parent hash");

        SafeTxLib.SafeTx memory approval = SafeTxLib.approvalTxWithPreimage(parent, parentHash, RC_CHILD, 205, "1.3.0");
        require(
            keccak256(approval.data) == keccak256(vm.parseBytes(_read("nested-preimage-child-205.hex"))),
            "calldata differs from the executed approval"
        );
        _assertEq(approval.hash(), 0xcce0f737311aecf1b4a54acae4d57231d60c435e764e3cbc924a9a4a15f707cb, "child hash");
        require(bytes4(approval.data) == SafeTxLib.APPROVE_HASH_SELECTOR, "still approveHash");
    }

    /// The suffix is built from the parent, so any change to it changes the approval,
    /// and the plain form is unaffected.
    function test_PreimageApprovalFollowsTheParent() external view {
        SafeTxLib.SafeTx memory parent = SafeTxLib.readCanonical(_read("nested-preimage-parent.json"));
        bytes32 h = parent.hash();
        bytes32 base = SafeTxLib.approvalTxWithPreimage(parent, h, RC_CHILD, 205, "1.3.0").hash();

        parent.nonce += 1;
        require(SafeTxLib.approvalTxWithPreimage(parent, h, RC_CHILD, 205, "1.3.0").hash() != base, "parent nonce");
        parent.nonce -= 1;
        parent.data = bytes.concat(parent.data, hex"00");
        require(SafeTxLib.approvalTxWithPreimage(parent, h, RC_CHILD, 205, "1.3.0").hash() != base, "parent data");

        require(SafeTxLib.approvalTx(parent.safe, h, RC_CHILD, 205, 1, "1.3.0").data.length == 36, "plain stays 36 bytes");
    }

    /// The check is phrased over a set, so a child that bundles its approval with
    /// other calls reads the same way as a lone approval.
    function test_FindsTheApprovalAmongOtherCalls() external pure {
        SafeTxLib.InnerTx[] memory txs = new SafeTxLib.InnerTx[](3);
        txs[0] = SafeTxLib.InnerTx({to: address(0xFEED), value: 0, data: hex"deadbeef", operation: 0});
        txs[1] = SafeTxLib.InnerTx({
            to: PARENT, value: 0, operation: 0,
            data: abi.encodeWithSelector(SafeTxLib.APPROVE_HASH_SELECTOR, PARENT_HASH)
        });
        txs[2] = SafeTxLib.InnerTx({to: address(0xFEED), value: 1 ether, data: "", operation: 0});

        require(SafeTxLib.approvedHashIn(txs, PARENT) == PARENT_HASH, "not found in a batch");
    }

    function test_RejectsMissingOrAmbiguousApproval() external {
        SafeTxLib.InnerTx[] memory none = new SafeTxLib.InnerTx[](1);
        none[0] = SafeTxLib.InnerTx({to: address(0xFEED), value: 0, data: hex"deadbeef", operation: 0});
        (bool a, bytes memory errA) = address(this).call(abi.encodeCall(this.approvedHashInExternal, (none, PARENT)));
        require(!a && _contains(errA, "no approveHash call"), "missing approval accepted");

        // An approveHash aimed at some other Safe is not this parent's approval.
        SafeTxLib.InnerTx[] memory wrongTarget = new SafeTxLib.InnerTx[](1);
        wrongTarget[0] = SafeTxLib.InnerTx({
            to: address(0xB0B), value: 0, operation: 0,
            data: abi.encodeWithSelector(SafeTxLib.APPROVE_HASH_SELECTOR, PARENT_HASH)
        });
        (bool b,) = address(this).call(abi.encodeCall(this.approvedHashInExternal, (wrongTarget, PARENT)));
        require(!b, "approval aimed elsewhere accepted");

        // Two approvals in one transaction is ambiguous. Which did they sign for?
        SafeTxLib.InnerTx[] memory two = new SafeTxLib.InnerTx[](2);
        two[0] = SafeTxLib.InnerTx({
            to: PARENT, value: 0, operation: 0,
            data: abi.encodeWithSelector(SafeTxLib.APPROVE_HASH_SELECTOR, PARENT_HASH)
        });
        two[1] = SafeTxLib.InnerTx({
            to: PARENT, value: 0, operation: 0,
            data: abi.encodeWithSelector(SafeTxLib.APPROVE_HASH_SELECTOR, bytes32(0))
        });
        (bool c, bytes memory errC) = address(this).call(abi.encodeCall(this.approvedHashInExternal, (two, PARENT)));
        require(!c && _contains(errC, "more than one approval"), "ambiguous approval accepted");
    }

    /// An entry with the parent as target and approveHash calldata, but executed as
    /// a DELEGATECALL or carrying value, is not an approval. It runs the parent's
    /// code against the child's storage, or moves ether, and approves nothing. It
    /// reads like an approval to anyone eyeballing `to` and the selector.
    function test_OnlyAZeroValueCallCountsAsAnApproval() external {
        bytes memory data = abi.encodeWithSelector(SafeTxLib.APPROVE_HASH_SELECTOR, PARENT_HASH);

        SafeTxLib.InnerTx[] memory delegate = new SafeTxLib.InnerTx[](1);
        delegate[0] = SafeTxLib.InnerTx({to: PARENT, value: 0, data: data, operation: 1});
        (bool a,) = address(this).call(abi.encodeCall(this.approvedHashInExternal, (delegate, PARENT)));
        require(!a, "a DELEGATECALL counted as an approval");

        SafeTxLib.InnerTx[] memory valued = new SafeTxLib.InnerTx[](1);
        valued[0] = SafeTxLib.InnerTx({to: PARENT, value: 1 ether, data: data, operation: 0});
        (bool b,) = address(this).call(abi.encodeCall(this.approvedHashInExternal, (valued, PARENT)));
        require(!b, "a value-bearing call counted as an approval");

        // A real approval alongside a disguised one is still found.
        SafeTxLib.InnerTx[] memory mixed = new SafeTxLib.InnerTx[](2);
        mixed[0] = delegate[0];
        mixed[1] = SafeTxLib.InnerTx({to: PARENT, value: 0, data: data, operation: 0});
        require(SafeTxLib.approvedHashIn(mixed, PARENT) == PARENT_HASH, "real approval missed");
    }

    function _one(SafeTxLib.SafeTx memory t) private pure returns (SafeTxLib.InnerTx[] memory out) {
        out = new SafeTxLib.InnerTx[](1);
        out[0] = SafeTxLib.InnerTx({to: t.to, value: t.value, data: t.data, operation: t.operation});
    }

    // ------------------------------------------------------- external trampolines

    // `require` inside an internal library call can only be caught across a real
    // call boundary, so the revert-path tests go through these.

    function readBatchExternal(string calldata json) external view returns (uint256) {
        return SafeTxLib.readBatch(json).length;
    }

    function toSafeTxExternal(SafeTxLib.InnerTx[] calldata txs, SafeTxLib.Binding calldata b, uint256 chainId)
        external
        view
        returns (bytes32)
    {
        return SafeTxLib.toSafeTx(txs, b, chainId).hash();
    }

    function hashExternal(SafeTxLib.SafeTx calldata t) external pure returns (bytes32) {
        return SafeTxLib.hash(t);
    }

    function readAnyExternal(string calldata json, SafeTxLib.Binding calldata b) external view returns (bytes32) {
        SafeTxLib.Binding memory binding = b;
        return SafeTxLib.readAny(json, binding).hash();
    }

    function approvalTxExternal(address parent, bytes32 h, address child, uint256 nonce, uint256 chainId)
        external
        pure
        returns (bytes32)
    {
        return SafeTxLib.approvalTx(parent, h, child, nonce, chainId, "1.3.0").hash();
    }

    function approvedHashInExternal(SafeTxLib.InnerTx[] calldata txs, address parent) external pure returns (bytes32) {
        return SafeTxLib.approvedHashIn(txs, parent);
    }

    function defaultMultiSendExternal(string calldata version, uint256 chainId) external view returns (address) {
        return SafeTxLib.defaultMultiSend(version, chainId);
    }

    // ----------------------------------------------------------------- utilities

    function _copy(SafeTxLib.InnerTx[] memory src) private pure returns (SafeTxLib.InnerTx[] memory out) {
        out = new SafeTxLib.InnerTx[](src.length);
        for (uint256 i = 0; i < src.length; i++) {
            out[i] = SafeTxLib.InnerTx({to: src[i].to, value: src[i].value, data: bytes.concat(src[i].data), operation: src[i].operation});
        }
    }

    function _contains(bytes memory haystack, string memory needle) private pure returns (bool) {
        bytes memory n = bytes(needle);
        if (n.length == 0 || haystack.length < n.length) return false;
        for (uint256 i = 0; i <= haystack.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (haystack[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
