// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../config/ProtocolConfig.sol";

/// @title Stable Token Contract
/// @notice A stablecoin contract that supports minting and burning with access control
/// @dev Inherits OpenZeppelin's ERC20. Access control is managed by ProtocolConfig.
contract StableToken is ERC20 {

    ProtocolConfig public immutable config;

    /// @notice The TrancheVault smart contract or address responsible for token minting and burning
    /// @dev Only the TrancheVault can call the mint and burn functions
    address public trancheVault;


    event TrancheVaultChanged(address indexed oldTrancheVault, address indexed newTrancheVault);
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);


    /// @notice Access control modifier: ensures the caller is the current TrancheVault
    modifier onlyTrancheVault() {
        require(msg.sender == trancheVault, "Only TrancheVault");
        _;
    }
    
 
    modifier onlyAdmin() {
        require(config.hasRole(config.DEFAULT_ADMIN_ROLE(), msg.sender), "Not admin");
        _;
    }

    /// @notice Contract constructor
    /// @dev Initializes the token name and symbol, and sets the ProtocolConfig
    constructor(address _config, address _trancheVault) 
        ERC20("Stable Token", "S") 
    {
        require(_config != address(0), "Invalid config address");
        config = ProtocolConfig(_config);
        trancheVault = _trancheVault;
    }
    
    /// @notice Sets a new TrancheVault address
    /// @dev Only an admin can call this function to update the TrancheVault
    /// @param _trancheVault The new TrancheVault address, cannot be the zero address
    function setTrancheVault(address _trancheVault) external onlyAdmin {
        require(_trancheVault != address(0), "Invalid TrancheVault address");
        address oldTrancheVault = trancheVault;
        trancheVault = _trancheVault;
        emit TrancheVaultChanged(oldTrancheVault, _trancheVault);
    }
    
    /// @notice Mints new stablecoins
    /// @dev Only the configured TrancheVault can call this minting function
    /// @param to The address receiving the new tokens, cannot be the zero address
    /// @param amount The amount of tokens to mint, must be greater than 0
    function mint(address to, uint256 amount) external onlyTrancheVault {
        require(to != address(0), "Cannot mint to zero address");
        require(amount > 0, "Amount must be positive");
        _mint(to, amount);
        emit Minted(to, amount);
    }
    
    /// @notice Burns stablecoins from a specified user
    /// @dev Only the configured TrancheVault can call this burning function, and the user must have sufficient balance
    /// @param from The address from which tokens will be deducted and burned, cannot be the zero address
    /// @param amount The amount of tokens to burn, must be greater than 0
    function burn(address from, uint256 amount) external onlyTrancheVault {
        require(from != address(0), "Cannot burn from zero address");
        require(amount > 0, "Amount must be positive");
        require(balanceOf(from) >= amount, "Insufficient balance to burn");
        _burn(from, amount);
        emit Burned(from, amount);
    }
    
    /// @notice Retrieves the current TrancheVault address
    /// @return The TrancheVault address currently responsible for minting/burning
    function getTrancheVault() external view returns (address) {
        return trancheVault;
    }
    
}