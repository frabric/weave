// SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import "./DistributionERC20.sol";
import "./FrabricWhitelist.sol";
import "./IntegratedLimitOrderDEX.sol";

import "../interfaces/erc20/IAuction.sol";

import "../interfaces/erc20/IFrabricERC20.sol";

// FrabricERC20s are tokens with a built in limit order DEX, along with governance and distribution functionality
// The owner can also mint tokens, with a whitelist enforced unless disabled by owner, defaulting to a parent whitelist
// Finally, the owner can pause transfers, intended for migrations and dissolutions
contract FrabricERC20 is OwnableUpgradeable, PausableUpgradeable, DistributionERC20, FrabricWhitelist, IntegratedLimitOrderDEX, IFrabricERC20Initializable {
  using ERC165Checker for address;

  bool public override mintable;
  address public override auction;

  mapping(address => uint64) public override frozenUntil;
  mapping(address => uint8) public override removalFee;
  bool private _removal;

  function initialize(
    string memory name,
    string memory symbol,
    uint256 supply,
    bool _mintable,
    address parent,
    address tradeToken,
    address _auction
  ) external override initializer {
    __Ownable_init();
    __Pausable_init();
    __DistributionERC20_init(name, symbol);
    __FrabricWhitelist_init(parent);
    __IntegratedLimitOrderDEX_init(tradeToken);

    __Composable_init("FrabricERC20", false);
    supportsInterface[type(OwnableUpgradeable).interfaceId] = true;
    supportsInterface[type(PausableUpgradeable).interfaceId] = true;
    supportsInterface[type(IRemovalFee).interfaceId] = true;
    supportsInterface[type(IFreeze).interfaceId] = true;
    supportsInterface[type(IFrabricERC20).interfaceId] = true;

    // Whitelist the initializer
    // This is the Frabric's deployer/the ThreadDeployer
    // If the former, they should remove their own whitelisting
    // If the latter, this is intended behavior
    _setWhitelisted(msg.sender, keccak256("Initializer"));

    // Make sure the supply is within bounds
    // The DAO code sets an upper bound of signed<int>.max
    // Uniswap and more frequently use uint112 which is a perfectly functional bound
    // The DAO code accordingly uses int128 which maintains storage efficiency
    // while supporting the full uint112 range
    if (supply > uint256(type(uint112).max)) {
      revert SupplyExceedsUInt112(supply);
    }

    // Mint the supply
    _mint(msg.sender, supply);
    mintable = _mintable;

    auction = _auction;

    _removal = false;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() Composable("FrabricERC20") initializer {}

  // Redefine ERC20 functions so the DEX can pick them up as overrides and call them
  function _transfer(address from, address to, uint256 amount) internal override(ERC20Upgradeable, IntegratedLimitOrderDEX) {
    super._transfer(from, to, amount);
  }
  function balanceOf(
    address account
  ) public view override(IERC20Upgradeable, ERC20Upgradeable, IntegratedLimitOrderDEX) returns (uint256) {
    return super.balanceOf(account);
  }
  function decimals() public view override(ERC20Upgradeable, IntegratedLimitOrderDEX) returns (uint8) {
    return super.decimals();
  }

  // Also define frozen so the DEX can prevent further orders from being placed
  function frozen(address person) public view override(IFreeze, IntegratedLimitOrderDEX) returns (bool) {
    return block.timestamp <= frozenUntil[person];
  }

  function mint(address to, uint256 amount) external override onlyOwner {
    if (!mintable) {
      revert NotMintable();
    }
    _mint(to, amount);
    if (totalSupply() > uint256(type(uint112).max)) {
      revert SupplyExceedsUInt112(totalSupply());
    }
  }

  function burn(uint256 amount) external override {
    _burn(msg.sender, amount);
  }

  function freeze(address person, uint64 until) external override onlyOwner {
    frozenUntil[person] = until;
    emit Freeze(person, until);
  }

  function triggerFreeze(address person) external override {
    // Doesn't need an address 0 check as it's using supportsInterface
    // Even if this was address 0 and we somehow got 0 values out of it,
    // it wouldn't be an issue
    if (parent.supportsInterface(type(IFreeze).interfaceId)) {
      uint64 until = IFreeze(parent).frozenUntil(person);
      if (until > frozenUntil[person]) {
        frozenUntil[person] = until;
      }
    }
  }

  // Labelled unsafe due to its split checks with triggerRemoval and lack of
  // guarantees on what checks it will perform
  function _removeUnsafe(address person, uint8 fee) internal override {
    // If they were already removed, return
    if (removed(person)) {
      return;
    }

    // If we didn't specify a fee, carry the parent's
   // Checks if it supports IRemovalFee, as that isn't actually a requirement on
   // parent. Solely IWhitelist is, and doing this check keeps the parent bounds
   // accordingly minimal and focused. It's also only a minor gas cost given how
   // infrequent removals are
    if (
      (fee == 0) &&
      // Redundant thanks to supportsInterface
      (parent != address(0)) &&
      (parent.supportsInterface(type(IRemovalFee).interfaceId))
    ) {
      fee = IRemovalFee(parent).removalFee(person);
    }

    _setRemoved(person);
    removalFee[person] = fee;

    // Clear the amount they have locked
    locked[person] = 0;

    uint256 balance = balanceOf(person);
    if (balance != 0) {
      // Send the removal fee to the owner (the DAO)
      uint256 actualFee = balance * fee / 100;
      // actualFee may be 0, yet balance will always remain non-0
      balance -= actualFee;
      _transfer(person, owner(), actualFee);

      // Put the rest up for auction
      _approve(person, auction, balance);

      // _removal is dangerous and this would be incredibly risky if re-entrancy
      // was possible, or if it was left set, yet every function which calls this
      // is nonReentrant and it is set to false immediately after this call to
      // trusted code
      _removal = true;
      IAuctionCore(auction).list(
        address(this),
        tradeToken,
        person,
        balance,
        4,
        uint64(block.timestamp),
        1 weeks
      );
      _removal = false;
    }

    emit Removal(person, balance);
  }

  // Whitelist functions
  function whitelisted(
    address person
  ) public view override(IntegratedLimitOrderDEX, FrabricWhitelist, IWhitelist) returns (bool) {
    return super.whitelisted(person);
  }

  function removed(
    address person
  ) public view override(IntegratedLimitOrderDEX, FrabricWhitelist, IFrabricWhitelist) returns (bool) {
    return super.removed(person);
  }

  function setParent(address _parent) external override onlyOwner {
    _setParent(_parent);
  }

  function setWhitelisted(address person, bytes32 dataHash) external override onlyOwner nonReentrant {
    _setWhitelisted(person, dataHash);
  }

  // nonReentrant would be overkill given onlyOwner except this needs to not be the initial vector
  // while re-entrancy happens through functions labelled nonReentrant
  // While the only external calls should be completely in-ecosystem and therefore to trusted code,
  // _removeUnsafe really isn't the thing to play around with
  function remove(address person, uint8 fee) external override onlyOwner nonReentrant {
    _setRemoved(person);

    // This will only apply to the Frabric/Thread in question
    // For a Frabric removal, this will remove them from the global whitelist,
    // and enable calling remove on any Thread. For a Thread, this won't change
    // the whitelist at all, as it'll still be whitelisted on the Frabric
    _removeUnsafe(person, fee);
  }

  function triggerRemoval(address person) public override nonReentrant {
    // Check they were actually removed from the whitelist
    if (whitelisted(person)) {
      revert Whitelisted(person);
    }

    // Check they actually used this contract in some point
    // If they never held tokens, this could be someone who was never whitelisted
    // Even if they were at one point, they aren't now, and they have no data to clean up
    if (numCheckpoints(person) == 0) {
      revert NothingToRemove(person);
    }

    _removeUnsafe(person, 0);
  }

  // Pause functions
  function paused() public view override(PausableUpgradeable, IFrabricERC20) returns (bool) {
    return super.paused();
  }
  function pause() external override onlyOwner {
    _pause();
  }

  // Transfer requirements
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);

    if ((!_removal) && (!_inDEX)) {
      // Whitelisted from or minting
      // A non-whitelisted actor may have tokens if they were removed from the whitelist
      // and remove has yet to be called. That's why this code is inside `if !_removal`
      // !_inDEX is simply an optimization as the DEX checks traders are whitelisted itself

      // Technically, whitelisted is an interaction, as discussed in IntegratedLimitOrderDEX
      // As stated there, it's trusted to not be idiotic AND it's view, limiting potential
      if ((!whitelisted(from)) && (from != address(0))) {
        revert NotWhitelisted(from);
      }

      // Regarding !_removal, placed here as a gas optimization
      // The Auction contract transferred to during removals is whitelisted so this
      // could be outside this block without issue. If it wasn't whitelisted,
      // anyone could call remove on it, which would be exceptionally problematic
      // (and it couldn't transfer tokens to auction winners)
      if (!whitelisted(to)) {
        revert NotWhitelisted(to);
      }

      // If the person is being removed, or if the DEX is executing a standing order,
      // this is disregarded. It's only if they're trying to transfer after being frozen
      // that this should matter (and the DEX ensures they can't place new orders)
      if (frozen(from)) {
        revert Frozen(from);
      }
    }

    if (paused()) {
      revert CurrentlyPaused();
    }
  }

  function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual override {
    super._afterTokenTransfer(from, to, amount);
    // Require the balance of the sender be greater than the amount of tokens they have on the DEX
    if (balanceOf(from) < locked[from]) {
      revert BalanceLocked(balanceOf(from), locked[from]);
    }
  }
}
