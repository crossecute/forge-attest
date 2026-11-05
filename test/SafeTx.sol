// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Inline cheatcode surface. forge-attest's verifier has no Solidity
///      dependencies: no forge-std, nothing to `forge install`, nothing to drift.
interface Vm {
    function parseJsonBool(string calldata json, string calldata key) external view returns (bool);
    function parseJsonKeys(string calldata json, string calldata key) external pure returns (string[] memory);
    function parseJsonStringArray(string calldata json, string calldata key) external pure returns (string[] memory);
    function envString(string calldata name) external view returns (string memory);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
    function keyExistsJson(string calldata json, string calldata key) external view returns (bool);
    function parseJsonAddress(string calldata json, string calldata key) external view returns (address);
    function parseJsonUint(string calldata json, string calldata key) external view returns (uint256);
    function parseJsonBytes(string calldata json, string calldata key) external view returns (bytes memory);
    function parseJsonBytes32(string calldata json, string calldata key) external view returns (bytes32);
    function parseJsonUintArray(string calldata json, string calldata key) external view returns (uint256[] memory);
    function parseJsonString(string calldata json, string calldata key) external view returns (string memory);
    function parseBytes32(string calldata value) external pure returns (bytes32);
    function parseUint(string calldata value) external pure returns (uint256);
    function parseAddress(string calldata value) external pure returns (address);
    function toString(bytes32 value) external pure returns (string memory);
    function toString(uint256 value) external pure returns (string memory);
    function toString(address value) external pure returns (string memory);
}

/// @title SafeTxLib
/// @notice Solidity model of a Gnosis Safe transaction, plus readers for every
///         JSON shape forge-attest accepts. This is the *second, independent*
///         implementation of the hash derivation. `lib/derive.sh` computes the
///         same values with `cast`, and the two are compared on every run, so no
///         single implementation is trusted.
///
///         Targets Safe >= 1.3.0 (chainId in the EIP-712 domain, `baseGas` field
///         name), matching `lib/derive.sh`.
library SafeTxLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant SAFE_TX_TYPEHASH = keccak256(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
    );

    /// @dev The contracts Safe{Wallet} delegatecalls to execute a batch. `CallOnly`
    ///      is the default and refuses inner DELEGATECALLs; the plain MultiSend
    ///      allows them.
    address internal constant MULTI_SEND_CALL_ONLY_1_3_0 = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    address internal constant MULTI_SEND_CALL_ONLY_1_4_1 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address internal constant MULTI_SEND_CALL_ONLY_1_5_0 = 0xA83c336B20401Af773B6219BA5027174338D1836;

    /// @dev Chain-specific MultiSendCallOnly deployments from safe-global/safe-deployments.
    ///      Listed so the inner-DELEGATECALL guard recognizes all known CallOnly variants.
    address internal constant MULTI_SEND_CALL_ONLY_1_3_0_EIP155 = 0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B;
    address internal constant MULTI_SEND_CALL_ONLY_1_3_0_ZKSYNC = 0xf220D3b4DFb23C4ade8C88E526C1353AbAcbC38F;
    address internal constant MULTI_SEND_CALL_ONLY_1_4_1_ZKSYNC = 0x0408EF011960d02349d50286D20531229BCef773;

    /// @dev Chains whose MultiSendCallOnly is not the canonical address, generated
    ///      from safe-global/safe-deployments. Shared with lib/normalize.sh.
    string internal constant EXCEPTIONS_PATH = "lib/multisend-exceptions.json";

    /// @notice The full EIP-712 SafeTx field set, which is forge-attest's
    ///         canonical form.
    struct SafeTx {
        address safe;
        uint256 chainId;
        string safeVersion;
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
    }

    /// @notice One entry of a Transaction Builder batch.
    struct InnerTx {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    struct MethodEncoding {
        string signature;
        string keys;
        bytes arguments;
    }

    /// @dev `approveHash(bytes32)`. A Safe that owns another Safe cannot sign, so
    ///      it approves on-chain instead. The call stores a flag against
    ///      (owner, hash) and never learns the preimage. At execution the full
    ///      transaction is supplied again and re-hashed. Nothing on-chain can tell
    ///      a signer what they approved, which is why the parent's decoded intent
    ///      has to travel alongside.
    bytes4 internal constant APPROVE_HASH_SELECTOR = 0xd4d9bdcd;

    /// @notice What a batch or call cannot tell us and the config must supply.
    /// @dev The gas/refund fields are here because neither format ever carries
    ///      them. They are almost always zero, which is what the Safe UI submits.
    ///      They are still inputs to the hash, so a config that sets them has to
    ///      reach this side too, or the two derivations silently disagree.
    struct Binding {
        address safe;
        uint256 nonce;
        uint256 chainId; // 0 = take it from the JSON
        string safeVersion; // "" = 1.3.0
        address multiSend; // address(0) = canonical MultiSendCallOnly for safeVersion
        bool forceMultiSend; // wrap even a single-transaction batch
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
    }

    // ---------------------------------------------------------------- hashing

    function domainSeparator(uint256 chainId, address safe) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, chainId, safe));
    }

    function structHash(SafeTx memory t) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                t.to,
                t.value,
                keccak256(t.data),
                t.operation,
                t.safeTxGas,
                t.baseGas,
                t.gasPrice,
                t.gasToken,
                t.refundReceiver,
                t.nonce
            )
        );
    }

    /// @notice The digest Safe owners actually sign.
    function hash(SafeTx memory t) internal pure returns (bytes32) {
        require(atLeast130(t.safeVersion), "SafeTxLib: Safe < 1.3.0 is not supported by this deriver");
        return keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(t.chainId, t.safe), structHash(t))
        );
    }

    // ------------------------------------------------------------- multi-send

    /// @notice The packed MultiSend payload: for each transaction,
    ///         `abi.encodePacked(uint8 operation, address to, uint256 value,
    ///         uint256 data.length, bytes data)`.
    function encodeMultiSendPayload(InnerTx[] memory txs) internal pure returns (bytes memory payload) {
        for (uint256 i = 0; i < txs.length; i++) {
            payload = abi.encodePacked(payload, txs[i].operation, txs[i].to, txs[i].value, txs[i].data.length, txs[i].data);
        }
    }

    /// @notice `multiSend(bytes)` calldata for the packed payload.
    function encodeMultiSendCalldata(InnerTx[] memory txs) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("multiSend(bytes)", encodeMultiSendPayload(txs));
    }

    /// @notice Fold a batch into the single SafeTx its owners sign. This does
    ///         what Safe{Wallet} does when it submits a Transaction Builder batch.
    function toSafeTx(InnerTx[] memory txs, Binding memory b, uint256 jsonChainId)
        internal
        view
        returns (SafeTx memory t)
    {
        require(txs.length > 0, "SafeTxLib: batch contains no transactions");

        t.safe = b.safe;
        t.chainId = b.chainId == 0 ? jsonChainId : b.chainId;
        t.safeVersion = bytes(b.safeVersion).length == 0 ? "1.3.0" : b.safeVersion;
        t.nonce = b.nonce;
        t.safeTxGas = b.safeTxGas;
        t.baseGas = b.baseGas;
        t.gasPrice = b.gasPrice;
        t.gasToken = b.gasToken;
        t.refundReceiver = b.refundReceiver;
        require(t.safe != address(0), "SafeTxLib: no Safe address");
        require(t.chainId != 0, "SafeTxLib: no chainId");

        if (txs.length == 1 && !b.forceMultiSend) {
            t.to = txs[0].to;
            t.value = txs[0].value;
            t.data = txs[0].data;
            t.operation = txs[0].operation;
            return t;
        }

        address multiSend = b.multiSend;
        if (multiSend == address(0)) {
            multiSend = defaultMultiSend(t.safeVersion, t.chainId);
        }

        bool callOnly = _isCallOnly(multiSend);
        for (uint256 i = 0; i < txs.length; i++) {
            require(txs[i].operation <= 1, "SafeTxLib: inner operation must be 0 or 1");
            require(
                !(callOnly && txs[i].operation == 1),
                "SafeTxLib: inner DELEGATECALL rejected by MultiSendCallOnly"
            );
        }

        t.to = multiSend;
        t.value = 0;
        t.data = encodeMultiSendCalldata(txs);
        t.operation = 1; // MultiSend is always DELEGATECALLed from the Safe
    }

    // ------------------------------------------------------------ nested Safes

    /// @notice The transaction a child Safe sends to approve `parentHash` on the
    ///         parent Safe it owns. Every field is determined by the arguments.
    ///         There is nothing for a producer script to choose, so this is
    ///         constructed rather than read from an artifact.
    function approvalTx(
        address parentSafe,
        bytes32 parentHash,
        address childSafe,
        uint256 childNonce,
        uint256 chainId,
        string memory safeVersion
    ) internal pure returns (SafeTx memory t) {
        require(parentSafe != address(0), "SafeTxLib: no parent Safe");
        require(childSafe != address(0), "SafeTxLib: no child Safe");
        require(parentSafe != childSafe, "SafeTxLib: child and parent are the same Safe");
        require(chainId != 0, "SafeTxLib: no chainId");

        t.safe = childSafe;
        t.chainId = chainId;
        t.safeVersion = bytes(safeVersion).length == 0 ? "1.3.0" : safeVersion;
        t.to = parentSafe;
        t.value = 0;
        t.data = abi.encodeWithSelector(APPROVE_HASH_SELECTOR, parentHash);
        t.operation = 0;
        t.nonce = childNonce;
    }

    /// @notice The hash an approval commits to, read back out of its calldata.
    /// @dev Phrased over a set so a child that bundles its approval with other
    ///      calls can be checked the same way later; a lone approval is the
    ///      one-entry case.
    function approvedHashIn(InnerTx[] memory txs, address parentSafe) internal pure returns (bytes32 approved) {
        bool found;
        for (uint256 i = 0; i < txs.length; i++) {
            if (txs[i].to != parentSafe || txs[i].data.length != 36) continue;
            if (bytes4(txs[i].data) != APPROVE_HASH_SELECTOR) continue;
            // An approval is a plain zero-value CALL. An entry carrying the same
            // target and calldata under DELEGATECALL runs the parent's code against
            // the child's storage and approves nothing; with a value attached it
            // also moves ether. Either would read as an approval to anyone
            // eyeballing `to` and the selector, so neither counts as one here.
            if (txs[i].operation != 0 || txs[i].value != 0) continue;
            bytes memory d = txs[i].data;
            bytes32 h;
            assembly {
                h := mload(add(d, 36))
            }
            require(!found, "SafeTxLib: more than one approval in this transaction");
            (found, approved) = (true, h);
        }
        require(found, "SafeTxLib: no approveHash call targeting the parent Safe");
    }

    // ------------------------------------------------------------ JSON reading

    /// @notice Read forge-attest's canonical SafeTx JSON (all scalars quoted).
    function readCanonical(string memory json) internal view returns (SafeTx memory t) {
        t.safe = vm.parseJsonAddress(json, ".safe");
        t.chainId = vm.parseJsonUint(json, ".chainId");
        t.safeVersion = vm.keyExistsJson(json, ".safeVersion") ? vm.parseJsonString(json, ".safeVersion") : "1.3.0";
        t = readSignedFields(json, "", t);
    }

    function readSignedFields(string memory json, string memory at, SafeTx memory t)
        private view returns (SafeTx memory)
    {
        t = readSignedCore(json, at, t);
        t.gasToken = vm.parseJsonAddress(json, string.concat(at, ".gasToken"));
        t.refundReceiver = vm.parseJsonAddress(json, string.concat(at, ".refundReceiver"));
        return t;
    }

    function readSignedCore(string memory json, string memory at, SafeTx memory t)
        private view returns (SafeTx memory)
    {
        t.to = vm.parseJsonAddress(json, string.concat(at, ".to"));
        t.value = vm.parseJsonUint(json, string.concat(at, ".value"));
        t.data = _optionalBytes(json, string.concat(at, ".data"));
        t.operation = _readOperation(json, string.concat(at, ".operation"));
        t.safeTxGas = vm.parseJsonUint(json, string.concat(at, ".safeTxGas"));
        t.baseGas = vm.parseJsonUint(json, string.concat(at, ".baseGas"));
        t.gasPrice = vm.parseJsonUint(json, string.concat(at, ".gasPrice"));
        t.nonce = vm.parseJsonUint(json, string.concat(at, ".nonce"));
        return t;
    }

    function requireKeys(string memory json, string memory at, string memory expected) internal pure {
        allowKeys(json, at, expected);
        require(vm.parseJsonKeys(json, at).length == vm.parseJsonStringArray(expected, "$").length,
            "SafeTxLib: unexpected object keys");
    }

    function allowKeys(string memory json, string memory at, string memory expected) internal pure {
        string[] memory keys = vm.parseJsonKeys(json, at);
        string[] memory want = vm.parseJsonStringArray(expected, "$");
        for (uint256 i = 0; i < keys.length; i++) {
            bool found;
            for (uint256 j = 0; j < want.length; j++) {
                if (keccak256(bytes(keys[i])) == keccak256(bytes(want[j]))) found = true;
            }
            require(found, "SafeTxLib: unexpected object key");
        }
    }

    function readEip712(string memory json, Binding memory b, string memory profile) internal view returns (SafeTx memory t) {
        require(bytes(json).length <= 1048576, "SafeTxLib: reader input exceeds 1 MiB");
        require(bytes(profile).length == 0 || _is(profile, "safe") || _is(profile, "safe-utils"), "SafeTxLib: unknown typed-data profile");
        requireKeys(json, "$", '["domain","message","primaryType","types"]');
        require(_is(vm.parseJsonString(json, ".primaryType"), "SafeTx"), "SafeTxLib: primaryType is not SafeTx");
        requireKeys(json, ".domain", '["chainId","verifyingContract"]');
        bool hasDomain = vm.keyExistsJson(json, ".types.EIP712Domain");
        require(hasDomain || _is(profile, "safe-utils"), "SafeTxLib: missing domain type");
        requireKeys(json, ".types", hasDomain ? '["EIP712Domain","SafeTx"]' : '["SafeTx"]');
        string[10] memory names = ["to","value","data","operation","safeTxGas","baseGas","gasPrice","gasToken","refundReceiver","nonce"];
        string[10] memory types_ = ["address","uint256","bytes","uint8","uint256","uint256","uint256","address","address","uint256"];
        for (uint256 i = 0; i < names.length; i++) _checkType(json, ".types.SafeTx", i, names[i], types_[i]);
        require(!vm.keyExistsJson(json, ".types.SafeTx[10]"), "SafeTxLib: extra type field");
        if (hasDomain) {
            _checkType(json, ".types.EIP712Domain", 0, "chainId", "uint256");
            _checkType(json, ".types.EIP712Domain", 1, "verifyingContract", "address");
            require(!vm.keyExistsJson(json, ".types.EIP712Domain[2]"), "SafeTxLib: extra domain field");
        }
        requireKeys(json, ".message", '["to","value","data","operation","safeTxGas","baseGas","gasPrice","gasToken","refundReceiver","nonce"]');
        t.safe = vm.parseJsonAddress(json, ".domain.verifyingContract");
        t.chainId = strictUint(json, ".domain.chainId");
        t.safeVersion = bytes(b.safeVersion).length == 0 ? "1.3.0" : b.safeVersion;
        validateSignedFields(json, ".message");
        t = readSignedFields(json, ".message", t);
        require(t.safe != address(0) && t.chainId != 0, "SafeTxLib: missing Safe or chain");
        require(b.safe == address(0) || b.safe == t.safe, "SafeTxLib: safe mismatch");
        require(b.chainId == 0 || b.chainId == t.chainId, "SafeTxLib: chain mismatch");
    }

    function strictUint(string memory json, string memory path) internal view returns (uint256 result) {
        bytes memory raw = bytes(vm.parseJsonString(json, path));
        require(raw.length > 0 && raw.length <= 78, "SafeTxLib: invalid decimal integer");
        require(raw.length == 1 || raw[0] != "0", "SafeTxLib: noncanonical decimal integer");
        for (uint256 i = 0; i < raw.length; i++) require(raw[i] >= "0" && raw[i] <= "9", "SafeTxLib: invalid decimal integer");
        result = vm.parseUint(string(raw));
    }

    function validateSignedFields(string memory json, string memory at) internal view {
        string[6] memory uints = ["value","operation","safeTxGas","baseGas","gasPrice","nonce"];
        for (uint256 i = 0; i < uints.length; i++) strictUint(json, string.concat(at, ".", uints[i]));
        bytes memory data = bytes(vm.parseJsonString(json, string.concat(at, ".data")));
        require(data.length >= 2 && data[0] == "0" && data[1] == "x" && data.length % 2 == 0, "SafeTxLib: invalid signed data");
        vm.parseJsonBytes(json, string.concat(at, ".data"));
    }

    function readService(string memory json, Binding memory b, string memory profile) internal view returns (SafeTx memory t) {
        require(bytes(json).length <= 1048576, "SafeTxLib: reader input exceeds 1 MiB");
        bool utils = _is(profile, "safe-utils");
        require(utils || bytes(profile).length == 0 || _is(profile, "safe"), "SafeTxLib: unknown service profile");
        allowKeys(json, "$", '["safe","chainId","to","value","data","operation","safeTxGas","baseGas","gasPrice","gasToken","refundReceiver","nonce","sender","signature","origin","contractTransactionHash","safeTxHash"]');
        validateSignedFields(json, "");
        t.safe = vm.keyExistsJson(json, ".safe") ? vm.parseJsonAddress(json, ".safe") : b.safe;
        require(utils || vm.keyExistsJson(json, ".safe"), "SafeTxLib: service request missing safe");
        t.chainId = vm.keyExistsJson(json, ".chainId") ? strictUint(json, ".chainId") : b.chainId;
        t.safeVersion = bytes(b.safeVersion).length == 0 ? "1.3.0" : b.safeVersion;
        t = readSignedCore(json, "", t);
        if (!utils || vm.keyExistsJson(json, ".gasToken")) t.gasToken = vm.parseJsonAddress(json, ".gasToken");
        if (!utils || vm.keyExistsJson(json, ".refundReceiver")) t.refundReceiver = vm.parseJsonAddress(json, ".refundReceiver");
        require(!utils || (t.safeTxGas == 0 && t.baseGas == 0 && t.gasPrice == 0 &&
            t.gasToken == address(0) && t.refundReceiver == address(0)), "SafeTxLib: safe-utils gas/refund fields must be zero");
        require(t.safe != address(0) && t.chainId != 0, "SafeTxLib: missing Safe or chain");
        require(b.safe == address(0) || b.safe == t.safe, "SafeTxLib: safe mismatch");
        require(b.chainId == 0 || b.chainId == t.chainId, "SafeTxLib: chain mismatch");
        string[2] memory aliases = [".contractTransactionHash", ".safeTxHash"];
        for (uint256 i = 0; i < aliases.length; i++) {
            if (!vm.keyExistsJson(json, aliases[i])) continue;
            string memory carried = vm.parseJsonString(json, aliases[i]);
            bytes memory raw = bytes(carried);
            require(raw.length == 66 && raw[0] == "0" && raw[1] == "x", "SafeTxLib: malformed service hash");
            require(vm.parseBytes32(carried) == hash(t), "SafeTxLib: service hash mismatch");
        }
    }

    function readDecoded(string memory json, Binding memory b, string memory profile) internal view returns (SafeTx memory) {
        require(_is(profile, "static-v1"), "SafeTxLib: explicit static-v1 profile required");
        require(bytes(json).length <= 1048576, "SafeTxLib: reader input exceeds 1 MiB");
        allowKeys(json, "$", '["version","chainId","createdAt","meta","transactions"]');
        require(_is(vm.parseJsonString(json, ".version"), "1.0"), "SafeTxLib: unsupported batch version");
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(n), "]"))) {
            require(n < 128, "SafeTxLib: too many decoded calls");
            n++;
        }
        require(n > 0, "SafeTxLib: empty decoded batch");
        InnerTx[] memory txs = new InnerTx[](n);
        for (uint256 i = 0; i < n; i++) txs[i] = readDecodedInner(json, string.concat(".transactions[", vm.toString(i), "]"));
        address declared = readSafeAddress(json);
        require(declared == address(0) || b.safe == address(0) || declared == b.safe, "SafeTxLib: safe address mismatch");
        if (b.safe == address(0)) b.safe = declared;
        uint256 chain = vm.keyExistsJson(json, ".chainId") ? strictUint(json, ".chainId") : 0;
        require(b.chainId == 0 || chain == 0 || b.chainId == chain, "SafeTxLib: chain mismatch");
        return toSafeTx(txs, b, chain);
    }

    function readDecodedInner(string memory json, string memory at) private view returns (InnerTx memory t) {
        t.to = vm.parseJsonAddress(json, string.concat(at, ".to"));
        if (vm.keyExistsJson(json, string.concat(at, ".value"))) t.value = strictUint(json, string.concat(at, ".value"));
        if (vm.keyExistsJson(json, string.concat(at, ".operation"))) t.operation = _readOperation(json, string.concat(at, ".operation"));
        require(t.operation == 0, "SafeTxLib: static-v1 supports CALL only");
        string memory dataPath = string.concat(at, ".data");
        string memory raw = vm.keyExistsJson(json, dataPath) ? vm.parseJsonString(json, dataPath) : "";
        bool carriesData = bytes(raw).length != 0 && !_is(raw, "null");
        if (carriesData) t.data = vm.parseJsonBytes(json, dataPath);
        string memory methodPath = string.concat(at, ".contractMethod");
        if (!vm.keyExistsJson(json, string.concat(methodPath, ".name"))) {
            require(nullOrMissing(json, methodPath), "SafeTxLib: invalid method descriptor");
            string memory values = string.concat(at, ".contractInputsValues");
            if (!nullOrMissing(json, values)) requireKeys(json, values, '[]');
            return t;
        }
        bytes memory encoded = encodeDecodedMethod(json, at, t.value);
        require(!carriesData || keccak256(t.data) == keccak256(encoded), "SafeTxLib: descriptor/data mismatch");
        t.data = encoded;
    }

    function nullOrMissing(string memory json, string memory path) private view returns (bool) {
        if (!vm.keyExistsJson(json, path)) return true;
        try vm.parseJsonString(json, path) returns (string memory raw) { return _is(raw, "null"); }
        catch { return false; }
    }

    function encodeDecodedMethod(string memory json, string memory at, uint256 value) private view returns (bytes memory) {
        string memory method = string.concat(at, ".contractMethod");
        requireKeys(json, method, '["inputs","name","payable"]');
        string memory name = vm.parseJsonString(json, string.concat(method, ".name"));
        require(validIdentifier(name) && bytes(name).length <= 64 && !_is(name, "receive") && !_is(name, "fallback"), "SafeTxLib: invalid method name");
        bool payable_ = vm.parseJsonBool(json, string.concat(method, ".payable"));
        require(value == 0 || payable_, "SafeTxLib: value to nonpayable method");
        MethodEncoding memory encoding;
        encoding.signature = string.concat(name, "(");
        encoding.keys = "[";
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(method, ".inputs[", vm.toString(n), "]"))) {
            require(n < 32, "SafeTxLib: too many method inputs");
            (string memory typ, string memory key, bytes memory argument) = readDecodedArgument(json, at, n);
            encoding.arguments = bytes.concat(encoding.arguments, argument);
            if (n != 0) { encoding.signature = string.concat(encoding.signature, ","); encoding.keys = string.concat(encoding.keys, ","); }
            encoding.signature = string.concat(encoding.signature, typ);
            encoding.keys = string.concat(encoding.keys, '"', key, '"');
            n++;
        }
        if (n == 0) vm.parseJsonStringArray(json, string.concat(method, ".inputs"));
        if (n != 0 || !nullOrMissing(json, string.concat(at, ".contractInputsValues")))
            requireKeys(json, string.concat(at, ".contractInputsValues"), string.concat(encoding.keys, "]"));
        return abi.encodePacked(bytes4(keccak256(bytes(string.concat(encoding.signature, ")")))), encoding.arguments);
    }

    function readDecodedArgument(string memory json, string memory at, uint256 n)
        private view returns (string memory typ, string memory key, bytes memory argument)
    {
        string memory input = string.concat(at, ".contractMethod.inputs[", vm.toString(n), "]");
        allowKeys(json, input, '["name","type","internalType"]');
        typ = vm.parseJsonString(json, string.concat(input, ".type"));
        key = vm.parseJsonString(json, string.concat(input, ".name"));
        require(bytes(key).length == 0 || validIdentifier(key), "SafeTxLib: invalid input name");
        if (bytes(key).length == 0) key = vm.toString(n);
        argument = encodeStaticValue(json, string.concat(at, '.contractInputsValues["', key, '"]'), typ);
    }

    function encodeStaticValue(string memory json, string memory path, string memory typ) private view returns (bytes memory) {
        string memory raw = vm.parseJsonString(json, path);
        if (_is(typ, "address")) {
            require(bytes(raw).length == 42, "SafeTxLib: invalid method address");
            return abi.encode(vm.parseAddress(raw));
        }
        if (_is(typ, "bool")) {
            require(_is(raw, "true") || _is(raw, "false"), "SafeTxLib: bool must be true or false");
            return abi.encode(_is(raw, "true"));
        }
        require(_is(typ, "uint256") || _is(typ, "uint8"), "SafeTxLib: unsupported static-v1 type");
        uint256 number = strictUint(json, path);
        require(!_is(typ, "uint8") || number <= 255, "SafeTxLib: uint8 overflow");
        return abi.encode(number);
    }

    function validIdentifier(string memory name) private pure returns (bool) {
        bytes memory raw = bytes(name);
        if (raw.length == 0) return false;
        for (uint256 i = 0; i < raw.length; i++) {
            bytes1 c = raw[i];
            if (!((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" || (i > 0 && c >= "0" && c <= "9"))) return false;
        }
        return true;
    }

    function _checkType(string memory json, string memory base, uint256 i, string memory name, string memory typ) private view {
        string memory at = string.concat(base, "[", vm.toString(i), "]");
        requireKeys(json, at, '["name","type"]');
        require(_is(vm.parseJsonString(json, string.concat(at, ".name")), name) &&
            _is(vm.parseJsonString(json, string.concat(at, ".type")), typ), "SafeTxLib: incompatible typed-data schema");
    }

    function _is(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // ------------------------------------------------------------- zeus-traces

    bytes32 internal constant ZEUS_REQUIRE_MULTISIG = keccak256("ZeusRequireMultisig(address,uint8)");
    address internal constant ZEUS_VM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    /// @notice The calls a Zeus MultisigBuilder script makes as its multisig, from
    ///         `forge script --json` output. Independent of `reader_zeus` in
    ///         lib/readers.sh: it walks the entry call's `children` where the shell
    ///         filters on `parent`, and the two must select the same calls.
    function readZeus(string memory json, Binding memory b, string memory profile) internal view returns (SafeTx memory) {
        require(bytes(json).length <= 8388608, "SafeTxLib: zeus-traces input exceeds 8 MiB");
        require(bytes(profile).length == 0, "SafeTxLib: zeus-traces has no profiles");
        require(!b.forceMultiSend, "SafeTxLib: zeus-traces sends a single call directly");
        require(vm.parseJsonBool(json, ".success"), "SafeTxLib: forge script did not succeed");

        string memory base = _zeusExecutionArena(json);
        string memory root = string.concat(base, "[0]");
        require(_is(vm.parseJsonString(json, string.concat(root, ".trace.kind")), "CALL"), "SafeTxLib: malformed entry call");
        require(vm.parseJsonBool(json, string.concat(root, ".trace.success")), "SafeTxLib: malformed entry call");
        (address safe, uint8 callType) = _zeusEvent(json, vm.parseJsonAddress(json, string.concat(root, ".trace.address")));

        require(b.safe == address(0) || b.safe == safe, "SafeTxLib: safe address mismatch");
        b.safe = safe;

        InnerTx[] memory txs = _zeusCalls(json, base, safe, callType);
        require(txs.length == 1 || b.multiSend != address(0), "SafeTxLib: zeus-traces needs an explicit multisend_address");
        return toSafeTx(txs, b, 0);
    }

    function _zeusCalls(string memory json, string memory base, address safe, uint8 callType)
        private view returns (InnerTx[] memory txs)
    {
        string memory children = string.concat(base, "[0].children");
        require(vm.keyExistsJson(json, string.concat(children, "[0]")), "SafeTxLib: the script made no calls as the multisig");
        uint256[] memory ids = vm.parseJsonUintArray(json, children);
        txs = new InnerTx[](ids.length);
        uint256 n;
        for (uint256 i = 0; i < ids.length; i++) {
            string memory at = string.concat(base, "[", vm.toString(ids[i]), "].trace");
            if (_zeusSkips(json, at, safe)) continue;
            txs[n++] = InnerTx({
                to: vm.parseJsonAddress(json, string.concat(at, ".address")),
                value: _hexValue(vm.parseJsonString(json, string.concat(at, ".value"))),
                data: vm.parseJsonBytes(json, string.concat(at, ".data")),
                operation: callType
            });
        }
        require(n > 0, "SafeTxLib: the script made no calls as the multisig");
        assembly {
            mstore(txs, n)
        }
    }

    /// @dev True for reads and cheatcode calls, which are not part of the Safe
    ///      transaction. Anything else must be a successful CALL made as the multisig.
    function _zeusSkips(string memory json, string memory at, address safe) private view returns (bool) {
        string memory kind = vm.parseJsonString(json, string.concat(at, ".kind"));
        if (_is(kind, "STATICCALL")) return true;
        require(_is(kind, "CALL"), "SafeTxLib: the script makes a call other than CALL");
        if (vm.parseJsonAddress(json, string.concat(at, ".address")) == ZEUS_VM_ADDRESS) return true;
        require(vm.parseJsonAddress(json, string.concat(at, ".caller")) == safe, "SafeTxLib: call not made by the multisig");
        require(vm.parseJsonBool(json, string.concat(at, ".success")), "SafeTxLib: call reverted");
        return false;
    }

    function _zeusExecutionArena(string memory json) private view returns (string memory base) {
        uint256 blocks;
        for (uint256 i = 0; vm.keyExistsJson(json, string.concat(".traces[", vm.toString(i), "]")); i++) {
            string memory at = string.concat(".traces[", vm.toString(i), "]");
            if (_is(vm.parseJsonString(json, string.concat(at, "[0]")), "Execution")) {
                blocks++;
                base = string.concat(at, "[1].arena");
            }
        }
        require(blocks == 1, "SafeTxLib: expected exactly one Execution trace block");
    }

    function _zeusEvent(string memory json, address script) private view returns (address safe, uint8 callType) {
        uint256 found;
        for (uint256 i = 0; vm.keyExistsJson(json, string.concat(".raw_logs[", vm.toString(i), "]")); i++) {
            string memory at = string.concat(".raw_logs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, string.concat(at, ".topics[0]"))) continue;
            if (vm.parseJsonBytes32(json, string.concat(at, ".topics[0]")) != ZEUS_REQUIRE_MULTISIG) continue;
            found++;
            require(vm.parseJsonAddress(json, string.concat(at, ".address")) == script, "SafeTxLib: ZeusRequireMultisig not emitted by the script");
            require(!vm.keyExistsJson(json, string.concat(at, ".topics[1]")), "SafeTxLib: malformed ZeusRequireMultisig event");
            bytes memory data = vm.parseJsonBytes(json, string.concat(at, ".data"));
            require(data.length == 64, "SafeTxLib: malformed ZeusRequireMultisig event");
            uint256 kind;
            (safe, kind) = abi.decode(data, (address, uint256));
            require(kind <= 1, "SafeTxLib: callType must be 0 or 1");
            callType = uint8(kind);
        }
        require(found == 1, "SafeTxLib: expected exactly one ZeusRequireMultisig event");
        require(safe != address(0), "SafeTxLib: the multisig must not be the zero address");
    }

    /// @dev A call value as a hex quantity, limited to the exact range of a
    ///      JavaScript number because the Zeus CLI converts it through one.
    function _hexValue(string memory s) private pure returns (uint256 v) {
        bytes memory r = bytes(s);
        require(r.length >= 3 && r[0] == "0" && r[1] == "x", "SafeTxLib: malformed call value");
        for (uint256 i = 2; i < r.length; i++) {
            v = v * 16 + _hexDigit(r[i]);
            require(v <= 9007199254740991, "SafeTxLib: call value exceeds the exact range of a JavaScript number");
        }
    }

    function _hexDigit(bytes1 c) private pure returns (uint256) {
        if (c >= "0" && c <= "9") return uint8(c) - 48;
        if (c >= "a" && c <= "f") return uint8(c) - 87;
        if (c >= "A" && c <= "F") return uint8(c) - 55;
        revert("SafeTxLib: malformed call value");
    }

    function readWithFormat(string memory json, Binding memory b, string memory format, string memory profile)
        internal view returns (SafeTx memory)
    {
        if (_is(format, "zeus-traces")) return readZeus(json, b, profile);
        if (_is(format, "tx-builder-decoded") || (_is(profile, "static-v1") &&
            (_is(format, "tx-builder") || ((bytes(format).length == 0 || _is(format, "auto")) && vm.keyExistsJson(json, ".transactions"))))) {
            return readDecoded(json, b, profile);
        }
        bool typed = vm.keyExistsJson(json, ".primaryType") || vm.keyExistsJson(json, ".types") ||
            vm.keyExistsJson(json, ".domain") || vm.keyExistsJson(json, ".message");
        if (_is(format, "safe-eip712") || ((bytes(format).length == 0 || _is(format, "auto")) && typed)) {
            return readEip712(json, b, profile);
        }
        bool service = vm.keyExistsJson(json, ".contractTransactionHash") || vm.keyExistsJson(json, ".safeTxHash");
        if (_is(format, "safe-service") || ((bytes(format).length == 0 || _is(format, "auto")) && service)) {
            return readService(json, b, profile);
        }
        require(bytes(profile).length == 0, "SafeTxLib: profile unsupported for format");
        require(bytes(format).length == 0 || _is(format, "auto") || _is(format, "safe-tx") ||
            _is(format, "call") || _is(format, "tx-builder") || _is(format, "tx-array"), "SafeTxLib: unknown format");
        if (bytes(format).length != 0 && !_is(format, "auto")) {
            bool batch = vm.keyExistsJson(json, ".transactions");
            bool array_ = vm.keyExistsJson(json, "[0].to");
            bool call_ = vm.keyExistsJson(json, ".to") && !bindsSafeTx(json);
            require((_is(format, "tx-builder") && batch) || (_is(format, "tx-array") && array_) ||
                (_is(format, "call") && call_) || (_is(format, "safe-tx") && !typed && !batch && !array_ && !call_),
                "SafeTxLib: explicit format does not match input");
        }
        return _readLegacy(json, b);
    }

    /// @notice Read a Safe{Wallet} Transaction Builder batch (`.transactions`) or
    ///         a bare JSON array of the same entries.
    /// @dev Scalars may be JSON numbers or quoted strings. Producers differ, and
    ///      `parseJsonUint` accepts both. `operation` defaults to 0 (CALL).
    function readBatch(string memory json) internal view returns (InnerTx[] memory txs) {
        string memory base = vm.keyExistsJson(json, ".transactions[0].to") ? ".transactions" : "";

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(base, "[", vm.toString(n), "].to"))) {
            n++;
        }
        require(n > 0, "SafeTxLib: batch contains no transactions");

        txs = new InnerTx[](n);
        for (uint256 i = 0; i < n; i++) {
            txs[i] = _readInner(json, string.concat(base, "[", vm.toString(i), "]"));
        }
    }

    /// @notice Read a plain call `{ to, value?, data?, operation? }` as the
    ///         one-entry batch it is folded as.
    function readCall(string memory json) internal view returns (InnerTx[] memory txs) {
        txs = new InnerTx[](1);
        txs[0] = _readInner(json, "");
    }

    /// @notice True when the root object carries any SafeTx field a call lacks.
    /// @dev Such an object is read as a complete SafeTx, so a partial one reverts
    ///      instead of being completed from the binding. `lib/normalize.sh` uses
    ///      the same key list; the two must agree on which format a file is.
    function bindsSafeTx(string memory json) internal view returns (bool) {
        string[9] memory keys = [
            ".safe",
            ".chainId",
            ".safeVersion",
            ".safeTxGas",
            ".baseGas",
            ".gasPrice",
            ".gasToken",
            ".refundReceiver",
            ".nonce"
        ];
        for (uint256 i = 0; i < keys.length; i++) {
            if (vm.keyExistsJson(json, keys[i])) return true;
        }
        return false;
    }

    /// @notice chainId from a batch JSON, or 0 when the batch doesn't carry one
    ///         (a bare array never does).
    function readChainId(string memory json) internal view returns (uint256) {
        return vm.keyExistsJson(json, ".chainId") ? vm.parseJsonUint(json, ".chainId") : 0;
    }

    /// @notice The Safe a batch says it was built for, or address(0) if it doesn't
    ///         say. The Transaction Builder schema's slot for this is
    ///         `meta.createdFromSafeAddress`; producers that fill it in make the
    ///         file self-binding, and the configured Safe becomes a cross-check.
    function readSafeAddress(string memory json) internal view returns (address) {
        if (vm.keyExistsJson(json, ".safe")) return vm.parseJsonAddress(json, ".safe");
        if (vm.keyExistsJson(json, ".meta.createdFromSafeAddress")) {
            return vm.parseJsonAddress(json, ".meta.createdFromSafeAddress");
        }
        return address(0);
    }

    /// @notice Read any supported shape and fold it into the SafeTx to be signed.
    function readAny(string memory json, Binding memory b) internal view returns (SafeTx memory) {
        return readWithFormat(json, b, "auto", "");
    }

    function _readLegacy(string memory json, Binding memory b) private view returns (SafeTx memory) {
        if (vm.keyExistsJson(json, ".transactions[0].to") || vm.keyExistsJson(json, "[0].to")) {
            address declared = readSafeAddress(json);
            // Disagreement between the file and the config is a tampering signal,
            // not a preference to be resolved silently.
            require(
                declared == address(0) || b.safe == address(0) || declared == b.safe,
                "SafeTxLib: safe address mismatch between JSON and config"
            );
            if (b.safe == address(0)) b.safe = declared;
            return toSafeTx(readBatch(json), b, readChainId(json));
        }
        if (vm.keyExistsJson(json, ".to") && !bindsSafeTx(json)) {
            return toSafeTx(readCall(json), b, 0);
        }
        return readCanonical(json);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev One `{ to, value?, data?, operation? }` entry at JSON path `at`.
    function _readInner(string memory json, string memory at) private view returns (InnerTx memory) {
        require(
            !vm.keyExistsJson(json, string.concat(at, ".contractMethod"))
                || _optionalBytes(json, string.concat(at, ".data")).length > 0,
            "SafeTxLib: contractMethod without encoded data"
        );
        return InnerTx({
            to: vm.parseJsonAddress(json, string.concat(at, ".to")),
            value: vm.keyExistsJson(json, string.concat(at, ".value"))
                ? vm.parseJsonUint(json, string.concat(at, ".value"))
                : 0,
            data: _optionalBytes(json, string.concat(at, ".data")),
            operation: vm.keyExistsJson(json, string.concat(at, ".operation"))
                ? _readOperation(json, string.concat(at, ".operation"))
                : 0
        });
    }

    function _readOperation(string memory json, string memory key) private view returns (uint8) {
        uint256 operation = vm.parseJsonUint(json, key);
        require(operation <= 1, "SafeTxLib: operation must be 0 or 1");
        // forge-lint: disable-next-line(unsafe-typecast) bounded to 0 or 1 above
        return uint8(operation);
    }

    /// @dev `data` is routinely absent or explicitly `null` for plain value
    ///      transfers, which `parseJsonBytes` refuses outright. Only that case may
    ///      become empty calldata. A value that is present but not valid hex,
    ///      say `"0x1"`, is a producer bug, and silently hashing it as empty
    ///      would attest a transaction nobody wrote. A JSON null reads back as the
    ///      literal string "null", which is what separates the two.
    function _optionalBytes(string memory json, string memory key) private view returns (bytes memory) {
        if (!vm.keyExistsJson(json, key)) return "";
        try Vm(address(vm)).parseJsonString(json, key) returns (string memory raw) {
            if (keccak256(bytes(raw)) == keccak256(bytes("null"))) return "";
        } catch {}
        // Anything else must parse as hex; let the cheatcode's own error surface.
        return vm.parseJsonBytes(json, key);
    }

    /// @dev True for Safe >= 1.3.0, whose EIP-712 domain binds `chainId`. Older
    ///      Safes use a chainId-free domain and are out of scope here (the live
    ///      check via `safe_hashes.sh` still covers them).
    function atLeast130(string memory version) internal pure returns (bool) {
        (uint256 major, uint256 minor) = _majorMinor(version);
        if (major > 1) return true;
        return major == 1 && minor >= 3;
    }

    /// @dev Every MultiSendCallOnly deployment we know of, canonical and
    ///      chain-specific. These reject inner DELEGATECALLs, so a batch containing
    ///      one could never execute through them. Kept as a single list because
    ///      missing an entry here silently re-allows the very thing the guard
    ///      exists to catch.
    function _isCallOnly(address multiSend) private pure returns (bool) {
        return multiSend == MULTI_SEND_CALL_ONLY_1_3_0 || multiSend == MULTI_SEND_CALL_ONLY_1_3_0_ZKSYNC
            || multiSend == MULTI_SEND_CALL_ONLY_1_3_0_EIP155 || multiSend == MULTI_SEND_CALL_ONLY_1_4_1
            || multiSend == MULTI_SEND_CALL_ONLY_1_4_1_ZKSYNC || multiSend == MULTI_SEND_CALL_ONLY_1_5_0;
    }

    /// @notice The canonical MultiSendCallOnly for a Safe version.
    /// @dev Only versions whose deployment address we actually know are mapped.
    ///      Guessing for an unknown version would silently produce a `to` the Safe
    ///      never uses, a wrong hash that looks authoritative. Refuse instead and
    ///      make the caller name the address. `lib/normalize.sh` implements exactly
    ///      this mapping; the two must not drift, or the independent derivations
    ///      stop being a check on each other.
    function defaultMultiSend(string memory version, uint256 chainId) internal view returns (address) {
        (uint256 major, uint256 minor) = _majorMinor(version);
        address multiSend;
        string memory key;
        if (major == 1 && minor == 3) {
            (multiSend, key) = (MULTI_SEND_CALL_ONLY_1_3_0, "1.3.0");
        } else if (major == 1 && minor == 4) {
            (multiSend, key) = (MULTI_SEND_CALL_ONLY_1_4_1, "1.4.1");
        } else if (major == 1 && minor == 5) {
            (multiSend, key) = (MULTI_SEND_CALL_ONLY_1_5_0, "1.5.0");
        } else {
            revert("SafeTxLib: no known MultiSendCallOnly for this Safe version, set multisend_address");
        }

        // The canonical address is not universal. See lib/multisend-exceptions.json.
        // Both implementations read that one file so they cannot drift apart. No
        // try/catch: a missing file or key means the guard is not running, which
        // must be loud rather than quietly skipped.
        uint256[] memory chains =
            vm.parseJsonUintArray(vm.readFile(EXCEPTIONS_PATH), string.concat(".[\"", key, "\"]"));
        for (uint256 i = 0; i < chains.length; i++) {
            require(
                chains[i] != chainId,
                "SafeTxLib: chain does not use the canonical MultiSendCallOnly, set multisend_address"
            );
        }

        return multiSend;
    }

    function _majorMinor(string memory version) private pure returns (uint256 major, uint256 minor) {
        bytes memory v = bytes(version);
        uint256 i;
        for (; i < v.length && v[i] != "."; i++) {
            major = major * 10 + _digit(v[i]);
        }
        for (i = i + 1; i < v.length && v[i] != "."; i++) {
            minor = minor * 10 + _digit(v[i]);
        }
    }

    function _digit(bytes1 c) private pure returns (uint256) {
        require(c >= "0" && c <= "9", "SafeTxLib: malformed safeVersion");
        return uint8(c) - 48;
    }
}
