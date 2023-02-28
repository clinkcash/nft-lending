// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IInitialization.sol";


contract Factory {
    event LogDeploy(address indexed masterContract, bytes data, address indexed cloneAddress);

    /// @notice Mapping from clone contracts to their masterContract.
    mapping(address => address) public masterContractOf;

    /// @notice Deploys a given master Contract as a clone.
    /// Any ETH transferred with this call is forwarded to the new clone.
    /// Emits `LogDeploy`.
    /// @param masterContract The address of the contract to clone.
    /// @param data Additional abi encoded calldata that is passed to the new clone via `IInitialization.init`.
    /// @param useCreate2 Creates the clone by using the CREATE2 opcode, in this case `data` will be used as salt.
    /// @return cloneAddress Address of the created clone contract.
    function deploy(
        address masterContract,
        bytes calldata data,
        bool useCreate2
    ) public payable returns (address cloneAddress) {
        require(masterContract != address(0), "Factory: No masterContract");
        if (useCreate2) {
            // each masterContract has different code already. So clones are distinguished by their data only.
            bytes32 salt = keccak256(data);
            cloneAddress = Clones.cloneDeterministic(masterContract, salt);
        } else {
            cloneAddress = Clones.clone(masterContract);
        }
        masterContractOf[cloneAddress] = masterContract;

        IInitialization(cloneAddress).init{value : msg.value}(data);

        emit LogDeploy(masterContract, data, cloneAddress);
    }
}