// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTxLib} from "./SafeTx.sol";
import {ReaderTestBase} from "./ReaderTestBase.sol";

contract ServiceReaderTest is ReaderTestBase {
    function test_ProfilesMatchPinnedTransaction() external view {
        string[2] memory fixtures = ["safe-service.json", "safe-service-safe-utils.json"];
        for (uint256 i = 0; i < fixtures.length; i++) {
            SafeTxLib.Binding memory b;
            b.safe = SAFE;
            b.chainId = 1;
            SafeTxLib.SafeTx memory t = SafeTxLib.readWithFormat(_read(fixtures[i]), b, "safe-service", i == 0 ? "" : "safe-utils");
            require(SafeTxLib.hash(t) == EXPECTED, "service hash differs from pinned transaction");
            require(t.nonce == 42 && t.gasToken == address(0), "signed fields changed");
        }
    }

    function test_AllCarriedHashesMustAgree() external {
        string memory json = _read("safe-service.json");
        _reject(_replace(json, '"signature": "0x"',
            '"signature": "0x", "safeTxHash": "0x0000000000000000000000000000000000000000000000000000000000000000"'), "safe-service", "");
        _reject(_replace(json, '"signature": "0x"', '"signature": "0x", "safeTxHash": null'), "safe-service", "");
    }

    function test_RejectsResponseObjectsAndInvalidProfiles() external {
        string memory json = _read("safe-service.json");
        _reject(_replace(json, '"signature": "0x"', '"signature": "0x", "executionDate": "2026-11-05"'), "safe-service", "");
        _reject(json, "safe-service", "wrong");
        _reject(_replace(_read("safe-service-safe-utils.json"), '"safeTxGas": "0"', '"safeTxGas": "1"'), "safe-service", "safe-utils");
    }

    function test_ServiceNeedsIndependentChainBinding() external {
        SafeTxLib.Binding memory b;
        (bool ok,) = address(this).call(abi.encodeCall(this.readExternal, (_read("safe-service.json"), b, "safe-service", "")));
        require(!ok, "service inferred its chain from the carried hash");
    }
}
