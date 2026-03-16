// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "../libraries/DataTypes.sol";
import "../config/ProtocolConfig.sol";

/// @title Leverage Token Contract
/// @notice An ERC1155 token contract for dynamic leverage trading positions.
/// @dev Inherits ERC1155. Configured via ProtocolConfig, TrancheVault manages mint/burn.
contract LeverageToken is ERC1155 {

    ProtocolConfig public immutable config;
    address public trancheVault;
    uint256 public nextTokenId = 1;
    mapping(uint256 => TokenInfo) public tokens;

    event TokenCreated(uint256 indexed tokenId, uint256 mintPriceInWei, uint256 LTVInBps, uint256 creationTime);
    event TokensMinted(address indexed to, uint256 indexed tokenId, uint256 amount);
    event TokensBurned(address indexed from, uint256 indexed tokenId, uint256 amount);
    event TrancheVaultChanged(address indexed oldTrancheVault, address indexed newTrancheVault);

    /// @dev Restricts function access to current TrancheVault.
    modifier onlyTrancheVault() {
        require(msg.sender == trancheVault, "Only TrancheVault");
        _;
    }


    /// @dev Restricts function access to admin.
    modifier onlyAdmin() {
        require(config.hasRole(config.DEFAULT_ADMIN_ROLE(), msg.sender), "Not admin");
        _;
    }

    /// @param _config ProtocolConfig address.
    /// @param _trancheVault Initial TrancheVault address.
    constructor(address _config, address _trancheVault) ERC1155("") {
        require(_config != address(0), "Invalid config address");
        config = ProtocolConfig(_config);
        trancheVault = _trancheVault;
    }

    /// @notice Returns on-chain text-only metadata (no image field).
    function uri(uint256 tokenId) public view override returns (string memory) {
        TokenInfo memory tokenInfo = tokens[tokenId];
        //if the token does not exist, creationTime will be 0, so this check also serves as existence check
        require(tokenInfo.creationTime != 0, "Token does not exist");
        
        string memory idStr = Strings.toString(tokenId);
        string memory mintPriceStr = Strings.toString(tokenInfo.mintPriceInWei / 1e18);
        string memory ltvStr = Strings.toString(tokenInfo.LTVInBps / 100);
        string memory createdAtStr = Strings.toString(tokenInfo.creationTime);

        // Text-only metadata for wallets/indexers. No image or media URL is required.
        bytes memory json = abi.encodePacked(
            '{',
                '"name":"Leverage Token From Underlying",',
                '"description":"Leverage token metadata (on-chain JSON, no image)",',
                '"attributes":[',
                    '{"trait_type":"tokenId","value":"', idStr, '"},',
                    '{"trait_type":"mintPrice (USD)","value":"', mintPriceStr, '"},',
                    '{"trait_type":"LTV (%)","value":"', ltvStr, '"},',
                    '{"trait_type":"creationTime","value":"', createdAtStr, '"}',
                ']',
            '}'
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @notice Sets a new TrancheVault.
    /// @dev Only callable by admin.
    function setTrancheVault(address _trancheVault) external onlyAdmin {
        require(_trancheVault != address(0), "Invalid TrancheVault address");
        address oldTrancheVault = trancheVault;
        trancheVault = _trancheVault;
        emit TrancheVaultChanged(oldTrancheVault, _trancheVault);
    }


    /// @notice Creates a token profile (if needed) and mints in one call.
    function mint(
        address to,
        uint256 underlyingAmountInWei,
        uint256 mintPriceInWei,
        uint256 LTVInBps,
        uint256 sAmountInWei,
        uint256 lAmountInWei
    ) external onlyTrancheVault returns (uint256 tokenId) {

        tokenId = nextTokenId++;
        uint256 creationTime = block.timestamp;
        tokens[tokenId] = TokenInfo({
            underlyingAmountInWei: underlyingAmountInWei,
            mintPriceInWei: mintPriceInWei,
            LTVInBps: LTVInBps,
            sAmountInWei: sAmountInWei,
            lAmountInWei: lAmountInWei,
            creationTime: creationTime,
            isLocked: false
        });
        _mint(to, tokenId, lAmountInWei, "");
        emit TokenCreated(tokenId,mintPriceInWei,  LTVInBps, creationTime);
        emit TokensMinted(to, tokenId, lAmountInWei);
        return tokenId;
    }

    /// @notice Burns leverage tokens from an address.
    function burn(
        address from,
        uint256 tokenId,
        uint256 amount
    ) external onlyTrancheVault {
        require(tokens[tokenId].creationTime != 0, "Token does not exist");
        _burn(from, tokenId, amount);
        emit TokensBurned(from, tokenId, amount);
    }

    function updateStokenAmount
    (
        uint256 tokenId,
        uint256 newSAmountInWei
    ) external onlyTrancheVault {
        require(tokens[tokenId].creationTime != 0, "Token does not exist");
        tokens[tokenId].sAmountInWei = newSAmountInWei;
    }

    function updateLtokenAmount
    (
        uint256 tokenId,
        uint256 newLAmountInWei
    ) external onlyTrancheVault {
        require(tokens[tokenId].creationTime != 0, "Token does not exist");
        tokens[tokenId].lAmountInWei = newLAmountInWei;
    }

    function updateUnderlyingAmount
    (
        uint256 tokenId,
        uint256 newUnderlyingAmountInWei
    ) external onlyTrancheVault {
        require(tokens[tokenId].creationTime != 0, "Token does not exist");
        tokens[tokenId].underlyingAmountInWei = newUnderlyingAmountInWei;
    }

    /// @notice Deletes the token profile when it is fully burned and closed.
    function deleteTokenInfo(uint256 tokenId) external onlyTrancheVault {
        require(tokens[tokenId].creationTime != 0, "Token does not exist");
        delete tokens[tokenId];
    }

    /// @notice Returns details for a token id.
    function getTokenInfo(uint256 tokenId)
        external
        view
        returns (
        uint256 underlyingAmountInWei, 
        uint256 mintPriceInWei, 
        uint256 LTVInBps,
        uint256 sAmountInWei, 
        uint256 lAmountInWei, 
        uint256 creationTime,
        bool isLocked)
    {
        TokenInfo memory tokenInfo = tokens[tokenId];
        require(tokenInfo.creationTime != 0, "Token does not exist");

        return (
            tokenInfo.underlyingAmountInWei,
            tokenInfo.mintPriceInWei,
            tokenInfo.LTVInBps,
            tokenInfo.sAmountInWei,
            tokenInfo.lAmountInWei,
            tokenInfo.creationTime,
            tokenInfo.isLocked
        );
    }


    /// @notice Returns whether a token id exists.
    function tokenExists(uint256 tokenId) public view returns (bool) {
        return tokens[tokenId].creationTime != 0;
    }


    /// @notice Returns mint price for a token id.
    function getMintPrice(uint256 tokenId) external view returns (uint256) {
        TokenInfo memory tokenInfo = tokens[tokenId];
        require(tokenInfo.creationTime != 0, "Token does not exist");
        return tokenInfo.mintPriceInWei;
    }

    /// @notice Returns the next token id to be assigned.
    function getNextTokenId() external view returns (uint256) {
        return nextTokenId;
    }

    /// @notice Alias to ERC1155 balanceOf.
    function balanceOfInWei(address account, uint256 id) public view returns (uint256) {
        return balanceOf(account, id);
    }

    /// @notice Override ERC1155 _update function to make tokens non-transferable (Soulbound)
    /// @dev Allows minting (from zero address) and burning (to zero address), but blocks transfers between users.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal virtual override {
        super._update(from, to, ids, values);

        // 允許鑄造 (from == address(0)) 或 銷毀 (to == address(0))
        // 禁止普通用戶之間的轉帳
        if (from != address(0) && to != address(0)) {
            revert("LeverageToken: Phase 1 tokens are non-transferable");
        }
    }

}
