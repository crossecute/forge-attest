// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTxLib} from "./SafeTx.sol";
import {ReaderTestBase} from "./ReaderTestBase.sol";

/// Batch entries may carry SafeTx fields. They must agree with the binding, as in
/// lib/normalize.sh, or the hash would ignore what the file says.
contract EntryBindingsTest is ReaderTestBase {
    string internal constant FIXTURE = "tx-builder-entry-bindings.json";

    function _binding() internal pure returns (SafeTxLib.Binding memory b) {
        b.safe = SAFE;
        b.chainId = 1;
        b.nonce = 42;
    }

    function test_EntryFieldsAtDefaultsHashLikeThePlainBatch() external view {
        SafeTxLib.Binding memory b = _binding();
        bytes32 bound = SafeTxLib.hash(SafeTxLib.readWithFormat(_read(FIXTURE), b, "tx-builder", ""));
        bytes32 plain = SafeTxLib.hash(SafeTxLib.readWithFormat(_read("tx-builder-single.json"), b, "tx-builder", ""));
        require(bound == plain, "entry defaults changed the hash");
    }

    function test_RejectsEntryFieldsThatDisagreeWithTheBinding() external {
        string memory json = _read(FIXTURE);
        string memory one = "0x0000000000000000000000000000000000000001";
        _reject(_replace(json, '"safeTxGas": "0"', '"safeTxGas": "100"'), "tx-builder", "");
        _reject(_replace(json, '"baseGas": "0"', '"baseGas": 1'), "tx-builder", "");
        _reject(_replace(json, '"gasPrice": "0"', '"gasPrice": "1"'), "tx-builder", "");
        _reject(_replace(json, '"gasToken": "0x0000000000000000000000000000000000000000"',
            string.concat('"gasToken": "', one, '"')), "tx-builder", "");
        _reject(_replace(json, '"refundReceiver": "0x0000000000000000000000000000000000000000"',
            string.concat('"refundReceiver": "', one, '"')), "tx-builder", "");
        _reject(_replace(json, '"nonce": 0', '"nonce": 7'), "tx-builder", "");
        _reject(_replace(json, '"nonce": 0', '"nonce": null'), "tx-builder", "");
        _reject(_replace(json, '"gasPrice": "0"', '"gasPrice": null'), "tx-builder", "");
    }

    function test_AcceptsEntryFieldsThatAgree() external view {
        SafeTxLib.Binding memory b = _binding();
        bytes32 plain = SafeTxLib.hash(SafeTxLib.readWithFormat(_read(FIXTURE), b, "tx-builder", ""));
        string memory sameNonce = _replace(_read(FIXTURE), '"nonce": 0', '"nonce": 42');
        require(SafeTxLib.hash(SafeTxLib.readWithFormat(sameNonce, b, "tx-builder", "")) == plain,
            "entry nonce equal to the claim changed the hash");

        b.safeTxGas = 100;
        string memory sameGas = _replace(_read(FIXTURE), '"safeTxGas": "0"', '"safeTxGas": "100"');
        SafeTxLib.readWithFormat(sameGas, b, "tx-builder", "");
    }

    function test_RejectsAZeroEntryGasWhenTheClaimSetsOne() external {
        SafeTxLib.Binding memory b = _binding();
        b.safeTxGas = 100;
        (bool ok,) = address(this).call(abi.encodeCall(this.readExternal, (_read(FIXTURE), b, "tx-builder", "")));
        require(!ok, "reader accepted a contradictory gas");
    }

    function test_BareArrayAndDecodedEntriesAreChecked() external {
        string memory arr = '[{"to":"0x000000000000000000000000000000000000dEaD","baseGas":"9"}]';
        _reject(arr, "tx-array", "");
        string memory decoded = _read("tx-builder-decoded.json");
        _reject(_replace(decoded, '"value": "0"', '"value": "0", "safeTxGas": "5"'), "tx-builder-decoded", "static-v1");
    }
}
