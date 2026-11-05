// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTxLib} from "./SafeTx.sol";
import {ReaderTestBase} from "./ReaderTestBase.sol";

contract Eip712ReaderTest is ReaderTestBase {
    function test_ProfilesMatchCanonicalAndPreserveOuterTransaction() external view {
        string[2] memory fixtures = ["safe-eip712.json", "safe-eip712-safe-utils.json"];
        for (uint256 i = 0; i < fixtures.length; i++) {
            SafeTxLib.Binding memory b;
            b.safe = SAFE;
            b.chainId = 1;
            SafeTxLib.SafeTx memory t = SafeTxLib.readWithFormat(_read(fixtures[i]), b, "safe-eip712", i == 0 ? "" : "safe-utils");
            require(SafeTxLib.hash(t) == EXPECTED, "typed vs pinned canonical hash");
            require(t.nonce == 42 && t.operation == 0, "signed fields");
        }
        SafeTxLib.Binding memory empty;
        string memory json = _replace(_read("safe-eip712.json"), '"operation": "0"', '"operation": "1"');
        SafeTxLib.SafeTx memory delegated = SafeTxLib.readWithFormat(json, empty, "auto", "");
        require(delegated.operation == 1 && delegated.to == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, "outer delegatecall changed");
    }

    function test_InvalidSchemasAndProfilesAreRejected() external {
        string memory json = _read("safe-eip712.json");
        _reject(_replace(json, '"primaryType": "SafeTx"', '"primaryType": "Other"'), "auto", "");
        _reject(_replace(json, '"type": "uint8"', '"type": "uint256"'), "safe-eip712", "");
        _reject(_replace(json, '"chainId": "1"', '"chainId": "1", "name": "Safe"'), "auto", "");
        _reject(_replace(json, '"operation": "0"', '"operation": "2"'), "safe-eip712", "");
        _reject(_read("safe-eip712-safe-utils.json"), "auto", "");
        _reject(json, "safe-eip712", "unverified");
        _reject(json, "call", "");
    }

    function test_NullSignedDataIsRejected() external {
        string memory json = _read("safe-eip712.json");
        string memory data = vm.parseJsonString(json, ".message.data");
        _reject(_replace(json, string.concat('"data": "', data, '"'), '"data": null'), "safe-eip712", "");
    }

    function strictUintExternal(string memory json) external view returns (uint256) {
        return SafeTxLib.strictUint(json, "$");
    }

    function test_NumericFieldsMatchPinnedTransaction() external view {
        SafeTxLib.Binding memory b;
        require(SafeTxLib.hash(SafeTxLib.readWithFormat(_read("safe-eip712-numeric.json"), b, "safe-eip712", "")) == EXPECTED,
            "numeric typed data differs from the pinned transaction");
    }

    function test_StrictUintDecimalRepresentations() external {
        require(this.strictUintExternal("0") == 0, "numeric zero");
        require(this.strictUintExternal("42") == 42, "numeric nonce");
        require(this.strictUintExternal("9007199254740991") == 9007199254740991, "numeric safe limit");
        string[8] memory invalid = ["-1", "1.5", "null", "true", "[]", "{}", '"042"', '"0x2a"'];
        for (uint256 i = 0; i < invalid.length; i++) {
            (bool ok,) = address(this).call(abi.encodeCall(this.strictUintExternal, (invalid[i])));
            require(!ok, string.concat("accepted invalid uint: ", invalid[i]));
        }
    }

    function test_MaxUintSurvivesWithoutTruncation() external view {
        string memory max_ = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
        string memory json = _replace(_read("safe-eip712.json"), '"value": "0"', string.concat('"value": "', max_, '"'));
        SafeTxLib.Binding memory b;
        require(SafeTxLib.readWithFormat(json, b, "safe-eip712", "").value == type(uint256).max, "uint256 truncated");
    }
}
