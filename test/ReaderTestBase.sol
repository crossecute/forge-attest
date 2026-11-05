// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, SafeTxLib} from "./SafeTx.sol";

abstract contract ReaderTestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant SAFE = 0x111CEEee040739fD91D29C34C33E6B3E112F2177;
    bytes32 internal constant EXPECTED = 0xd0e33f3b88aceb5122db6ad935c1d709c7602f8ed92fc6b27bdd507902bdf534;

    function readExternal(string memory json, SafeTxLib.Binding memory b, string memory format, string memory profile)
        external view returns (bytes32)
    {
        return SafeTxLib.hash(SafeTxLib.readWithFormat(json, b, format, profile));
    }

    function _read(string memory fixture) internal view returns (string memory) {
        return vm.readFile(string.concat("test/fixtures/", fixture));
    }

    function _reject(string memory json, string memory format, string memory profile) internal {
        SafeTxLib.Binding memory b;
        b.safe = SAFE;
        b.chainId = 1;
        b.nonce = 42;
        (bool ok,) = address(this).call(abi.encodeCall(this.readExternal, (json, b, format, profile)));
        require(!ok, "reader accepted invalid input");
    }

    function _replace(string memory source, string memory before_, string memory after_) internal pure returns (string memory) {
        bytes memory src = bytes(source);
        bytes memory needle = bytes(before_);
        for (uint256 i = 0; i + needle.length <= src.length; i++) {
            bool match_ = true;
            for (uint256 j = 0; j < needle.length; j++) if (src[i+j] != needle[j]) match_ = false;
            if (match_) return string.concat(string(_slice(src, 0, i)), after_, string(_slice(src, i+needle.length, src.length)));
        }
        revert("test mutation did not match fixture");
    }

    function _slice(bytes memory src, uint256 begin, uint256 end) private pure returns (bytes memory result) {
        result = new bytes(end-begin);
        for (uint256 i = begin; i < end; i++) result[i-begin] = src[i];
    }
}
