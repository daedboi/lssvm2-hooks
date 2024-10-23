// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Test721Custom is ERC721, Ownable {
    constructor() ERC721("Test721Custom", "T721C") {}

    function mint(address to, uint256 id) public {
        _mint(to, id);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return false;
    }
}
