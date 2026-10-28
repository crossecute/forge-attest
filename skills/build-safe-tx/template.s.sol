// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Inline cheatcode surface, so the producer needs no forge-std.
interface Vm {
    function toString(address value) external pure returns (string memory);
    function toString(uint256 value) external pure returns (string memory);
    function toString(bytes calldata value) external pure returns (string memory);
    function projectRoot() external view returns (string memory);
    function createDir(string calldata path, bool recursive) external;
    function writeFile(string calldata path, string calldata data) external;
}

/// @dev Declare every function a call uses, so `abi.encodeCall` type-checks the
///      arguments. `abi.encodeWithSignature` would accept a typo'd signature.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Builds one Safe transaction as a Transaction Builder batch at
///         `out/<OUTPUT_NAME>.json`. Every input is a constant and `createdAt` is
///         fixed at 0, so the bytes are identical on every run and forge-attest
///         can pin `expected_output_sha256`. `createdFromSafeAddress` binds the
///         file to one Safe. The nonce is not in this file: the attestation claim
///         supplies it.
contract BuildSafeTx {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant OUTPUT_NAME = "safe-tx";
    string internal constant DESCRIPTION = "Send 1 USDC to the burn address";
    uint256 internal constant CHAIN_ID = 1;
    address internal constant SAFE = 0x111CEEee040739fD91D29C34C33E6B3E112F2177;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant RECIPIENT = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant AMOUNT = 1_000000; // 1 USDC, 6 decimals

    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function _calls() internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call(USDC, 0, abi.encodeCall(IERC20.transfer, (RECIPIENT, AMOUNT)));
    }

    function run() external {
        Call[] memory calls = _calls();
        string memory txs;
        for (uint256 i; i < calls.length; i++) {
            txs = string.concat(txs, _tx(calls[i]), i + 1 < calls.length ? ",\n" : "\n");
        }

        string memory json = string.concat(
            "{\n",
            '  "version": "1.0",\n',
            '  "chainId": "', vm.toString(CHAIN_ID), '",\n',
            '  "createdAt": 0,\n',
            '  "meta": {\n',
            '    "name": "', OUTPUT_NAME, '",\n',
            '    "description": "', DESCRIPTION, '",\n',
            '    "createdFromSafeAddress": "', vm.toString(SAFE), '"\n',
            "  },\n",
            '  "transactions": [\n',
            txs,
            "  ]\n",
            "}\n"
        );

        string memory outDir = string.concat(vm.projectRoot(), "/out");
        vm.createDir(outDir, true);
        vm.writeFile(string.concat(outDir, "/", OUTPUT_NAME, ".json"), json);
    }

    function _tx(Call memory c) internal pure returns (string memory) {
        return string.concat(
            "    {",
            ' "to": "', vm.toString(c.to), '",',
            ' "value": "', vm.toString(c.value), '",',
            ' "data": "', vm.toString(c.data), '",',
            ' "operation": "0"',
            " }"
        );
    }
}
