// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SafeTxLib} from "./SafeTx.sol";
import {ReaderTestBase} from "./ReaderTestBase.sol";

contract ZeusReaderTest is ReaderTestBase {
    address internal constant MULTISIG = 0x684cf8978c2815716c85eAa237E311f5a44e9e09;
    address internal constant MULTISEND_1_4_1 = 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526;
    string internal constant FIRST_CALL =
        '{"depth":1,"success":true,"caller":"0x684cf8978c2815716c85eaa237e311f5a44e9e09","address":"0x25e5f8b1e7adf44518d35d5b2271f114e081f0e5","kind":"CALL","value":"0x0"';
    // The executed eigenx transaction, Safe 0x684c...9e09 nonce 0.
    bytes32 internal constant EIGENX = 0x9e338be37a1756a80652767968a61be506fce16a0cbbec8d7441ff5e7724f478;

    function _binding() private pure returns (SafeTxLib.Binding memory b) {
        b.chainId = 1;
        b.safeVersion = "1.4.1";
        b.multiSend = MULTISEND_1_4_1;
    }

    function readZeus(string memory json, SafeTxLib.Binding memory b, string memory profile)
        external view returns (bytes32)
    {
        return SafeTxLib.hash(SafeTxLib.readWithFormat(json, b, "zeus-traces", profile));
    }

    function _rejectZeus(string memory json, SafeTxLib.Binding memory b, string memory profile) private {
        (bool ok,) = address(this).call(abi.encodeCall(this.readZeus, (json, b, profile)));
        require(!ok, "zeus reader accepted invalid input");
    }

    function test_ReadsTheExecutedEigenxTransaction() external view {
        SafeTxLib.SafeTx memory t =
            SafeTxLib.readWithFormat(_read("zeus-traces.json"), _binding(), "zeus-traces", "");
        require(t.safe == MULTISIG && t.to == MULTISEND_1_4_1 && t.operation == 1, "batch not bound to the multisig");
        require(SafeTxLib.hash(t) == EIGENX, "zeus-traces differs from the executed transaction");
    }

    /// @dev The four calls the script source makes, encoded from their ABI
    ///      signatures rather than read back from the traces.
    function test_BatchIsTheScriptsFourCalls() external view {
        address permissions = 0x25E5F8B1E7aDf44518d35D5B2271f114e081f0E5;
        address controller = 0xc38d35Fc995e75342A21CBd6D770305b142Fbe67;
        address whitelister = 0xDECf19D1551e77DEfBe53eE2c38205A3f852163C;
        SafeTxLib.InnerTx[] memory calls = new SafeTxLib.InnerTx[](4);
        calls[0].to = permissions;
        calls[0].data = abi.encodeWithSignature("acceptAdmin(address)", controller);
        calls[1].to = permissions;
        calls[1].data = abi.encodeWithSignature(
            "setAppointee(address,address,address,bytes4)", controller, whitelister, controller,
            bytes4(keccak256("setMaxGlobalActiveApps(uint32)"))
        );
        calls[2].to = permissions;
        calls[2].data = abi.encodeWithSignature(
            "setAppointee(address,address,address,bytes4)", controller, whitelister, controller,
            bytes4(keccak256("setMaxActiveAppsPerUser(address,uint32)"))
        );
        calls[3].to = controller;
        calls[3].data = abi.encodeWithSignature("setMaxGlobalActiveApps(uint32)", uint32(100));
        SafeTxLib.SafeTx memory t =
            SafeTxLib.readWithFormat(_read("zeus-traces.json"), _binding(), "zeus-traces", "");
        require(keccak256(t.data) == keccak256(SafeTxLib.encodeMultiSendCalldata(calls)), "calls differ from the script");
    }

    function test_CallTypeOneMakesEveryInnerCallADelegatecall() external {
        string memory json = _replace(
            _read("zeus-traces.json"),
            "0x000000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000000",
            "0x000000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000001"
        );
        SafeTxLib.SafeTx memory t = SafeTxLib.readWithFormat(json, _binding(), "zeus-traces", "");
        require(t.operation == 1 && bytes1(t.data[4 + 32 + 32]) == 0x01, "inner call type not applied");
        SafeTxLib.Binding memory callOnly = _binding();
        callOnly.multiSend = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
        _rejectZeus(json, callOnly, "");
    }

    function test_RejectsWhatTheZeusCliWouldMisread() external {
        string memory json = _read("zeus-traces.json");
        SafeTxLib.Binding memory b = _binding();
        _rejectZeus(_replace(json, '{"success":true', '{"success":false'), b, "");
        _rejectZeus(json, b, "safe");
        // Several calls need the MultiSend its CLI chose, named by the claim.
        SafeTxLib.Binding memory bare = _binding();
        bare.multiSend = address(0);
        _rejectZeus(json, bare, "");
        SafeTxLib.Binding memory forced = _binding();
        forced.forceMultiSend = true;
        _rejectZeus(json, forced, "");
        SafeTxLib.Binding memory other = _binding();
        other.safe = SAFE;
        _rejectZeus(json, other, "");
    }

    function test_RejectsAnUnpranked_Reverted_OrNonCallAction() external {
        string memory json = _read("zeus-traces.json");
        SafeTxLib.Binding memory b = _binding();
        // Made by the script itself, which the Zeus CLI would include as the multisig's.
        _rejectZeus(_replace(json, FIRST_CALL, _replace(FIRST_CALL, "0x684cf8978c2815716c85eaa237e311f5a44e9e09", "0x9f7cf1d1f558e57ef88a59ac3d47214ef25b6a06")), b, "");
        // Reverted, which the Zeus CLI drops without a trace.
        _rejectZeus(_replace(json, FIRST_CALL, _replace(FIRST_CALL, '"success":true', '"success":false')), b, "");
        _rejectZeus(_replace(json, FIRST_CALL, _replace(FIRST_CALL, '"kind":"CALL"', '"kind":"CREATE"')), b, "");
        _rejectZeus(_replace(json, FIRST_CALL, _replace(FIRST_CALL, '"kind":"CALL"', '"kind":"DELEGATECALL"')), b, "");
    }

    function test_RejectsAmbiguousRunsAndEvents() external {
        string memory json = _read("zeus-traces.json");
        SafeTxLib.Binding memory b = _binding();
        _rejectZeus(_replace(json, '["Deployment"', '["Execution"'), b, "");
        _rejectZeus(_replace(json, "0x266451a6d1ed", "0x000000000000"), b, "");
        // The first "address" in the document is the event's emitter.
        _rejectZeus(_replace(json, '"address":"0x9f7cf1d1f558e57ef88a59ac3d47214ef25b6a06"', '"address":"0x25e5f8b1e7adf44518d35d5b2271f114e081f0e5"'), b, "");
        _rejectZeus(_replace(json, "0x000000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000000",
            "0x000000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000002"), b, "");
        _rejectZeus(_replace(json, "0x000000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000000",
            "0x000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"), b, "");
        // A non-zero byte above the 20-byte address.
        _rejectZeus(_replace(json, "0x000000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000000",
            "0x100000000000000000000000684cf8978c2815716c85eaa237e311f5a44e9e090000000000000000000000000000000000000000000000000000000000000000"), b, "");
    }

    function test_CallValueIsLimitedToExactJavascriptNumbers() external view {
        string memory json = _read("zeus-traces.json");
        SafeTxLib.Binding memory b = _binding();
        string memory max = _replace(json, FIRST_CALL, _replace(FIRST_CALL, '"value":"0x0"', '"value":"0x1fffffffffffff"'));
        SafeTxLib.SafeTx memory t = SafeTxLib.readWithFormat(max, b, "zeus-traces", "");
        require(t.to == MULTISEND_1_4_1, "value within range changed the batch");
        require(SafeTxLib.hash(t) != EIGENX, "value did not reach the packed batch");
    }

    function test_RejectsAValueAJavascriptNumberRounds() external {
        string memory json = _read("zeus-traces.json");
        _rejectZeus(
            _replace(json, FIRST_CALL, _replace(FIRST_CALL, '"value":"0x0"', '"value":"0x20000000000000"')), _binding(), ""
        );
    }

    function test_ZeusTracesIsNeverAutoDetected() external {
        SafeTxLib.Binding memory b = _binding();
        (bool ok,) = address(this).call(abi.encodeCall(this.readExternal, (_read("zeus-traces.json"), b, "auto", "")));
        require(!ok, "zeus-traces was read without being named");
    }
}
