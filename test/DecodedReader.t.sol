// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTxLib} from "./SafeTx.sol";
import {ReaderTestBase} from "./ReaderTestBase.sol";

contract DecodedReaderTest is ReaderTestBase {
    function test_IndependentEncodersMatchPinnedScalarVectors() external view {
        SafeTxLib.Binding memory b;
        b.nonce = 42;
        SafeTxLib.SafeTx memory single = SafeTxLib.readWithFormat(_read("tx-builder-decoded.json"), b, "tx-builder-decoded", "static-v1");
        require(SafeTxLib.hash(single) == EXPECTED, "decoded transfer differs from canonical");
        SafeTxLib.SafeTx memory vectors = SafeTxLib.readWithFormat(_read("tx-builder-static-vectors.json"), b, "tx-builder-decoded", "static-v1");
        require(SafeTxLib.hash(vectors) == 0xac7e4f66f96082eb8fcb6e8a83b3be32248aeee6c1b1bd13366e715d1aacff17, "static vector hash");
        require(SafeTxLib.hash(vectors) == SafeTxLib.hash(SafeTxLib.readAny(_read("tx-builder-static-encoded.json"), b)), "decoded and encoded vectors differ");
    }

    function test_RejectsUnsupportedAndContradictoryInputs() external {
        string memory json = _read("tx-builder-decoded.json");
        _reject(json, "tx-builder-decoded", "");
        _reject(json, "tx-builder-decoded", "unverified");
        _reject(_replace(json, '"data": null', '"data": "0x"'), "tx-builder-decoded", "static-v1");
        _reject(_replace(json, '"type": "uint256"', '"type": "bytes"'), "tx-builder-decoded", "static-v1");
        _reject(_replace(json, '"amount": "1000000"', '"amount": "1000000", "extra": "1"'), "tx-builder-decoded", "static-v1");
    }

    function test_DecodedAliasesRejectTopLevelSafeDeclarations() external {
        string[3] memory formats = ["auto", "tx-builder", "tx-builder-decoded"];
        string[2] memory keys = ["safe", "safeAddress"];
        string[2] memory addresses = [vm.toString(SAFE), vm.toString(address(0xB0B))];
        string memory json = _read("tx-builder-decoded.json");
        SafeTxLib.Binding memory b;
        b.safe = SAFE;
        b.chainId = 1;
        b.nonce = 42;
        for (uint256 i = 0; i < formats.length; i++) {
            require(SafeTxLib.hash(SafeTxLib.readWithFormat(json, b, formats[i], "static-v1")) == EXPECTED,
                "valid decoded batch changed");
            for (uint256 j = 0; j < keys.length; j++) {
                for (uint256 k = 0; k < addresses.length; k++) {
                    _reject(_replace(json, '"version":', string.concat('"', keys[j], '":"', addresses[k], '","version":')),
                        formats[i], "static-v1");
                }
            }
        }
    }

    function test_RejectsValueToNonpayableMethod() external {
        _reject(_replace(_read("tx-builder-decoded.json"), '"value": "0"', '"value": "1"'), "tx-builder-decoded", "static-v1");
    }

    function test_InputListMustBeAnArray() external {
        string memory json = '{"version":"1.0","chainId":"1","transactions":[{"to":"0x000000000000000000000000000000000000bEEF",'
            '"contractMethod":{"name":"ping","payable":false,"inputs":{}},"contractInputsValues":{}}]}';
        _reject(json, "tx-builder-decoded", "static-v1");
    }

    function test_NativeTransfersAndNullNoArgInputs() external view {
        SafeTxLib.Binding memory b;
        b.safe = SAFE; b.nonce = 42;
        string memory native_ = '{"version":"1.0","chainId":"1","transactions":[{"to":"0x000000000000000000000000000000000000bEEF",'
            '"value":"1","data":null,"contractMethod":null,"contractInputsValues":null}]}';
        SafeTxLib.SafeTx memory t = SafeTxLib.readWithFormat(native_, b, "tx-builder-decoded", "static-v1");
        require(t.value == 1 && t.data.length == 0 && t.operation == 0, "native transfer changed");
        string memory zeroArgs = _replace(_read("tx-builder-static-vectors.json"), '"contractInputsValues": {}', '"contractInputsValues": null');
        require(SafeTxLib.hash(SafeTxLib.readWithFormat(zeroArgs, b, "tx-builder-decoded", "static-v1")) ==
            0xac7e4f66f96082eb8fcb6e8a83b3be32248aeee6c1b1bd13366e715d1aacff17, "zero-argument method changed");
    }

    function test_RequiresProfileAndBoundsSourceSize() external {
        _reject(string(new bytes(1048577)), "tx-builder-decoded", "static-v1");
    }
}
