// SPDX-License-Identifier: AGPLv3
pragma solidity >=0.8.9;

interface IThreadDeployer {
  event Thread(
    address indexed agent,
    address indexed tradeToken,
    address erc20,
    address thread,
    address crowdfund
  );

  function crowdfundProxy() external view returns (address);
  function erc20Beacon() external view returns (address);
  function threadBeacon() external view returns (address);

  function lockup(address erc20) external view returns (uint256);

  function initialize(
    address frabric,
    address _crowdfundProxy,
    address _erc20Beacon,
    address _threadBeacon
  ) external;

  function deploy(
    string memory name,
    string memory symbol,
    address parentWhitelist,
    address agent,
    address raiseToken,
    uint256 target
  ) external;
}
