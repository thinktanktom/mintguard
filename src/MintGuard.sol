// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IMintGuard.sol";
import "./MintGuardLib.sol";
abstract contract MintGuard is IMintGuard {
    using MintGuardLib for MintGuardLib.MintRecord;
 
    // Storage: one record per address
    mapping(address => MintGuardLib.MintRecord) private _records;
    // Reverts if caller has no active mint record.
    // This is the primary Sybil guard.
    modifier onlyMinter() {
        require(_records[msg.sender].amount > 0, "MintGuard: caller is not a minter");
        _;
    }
 
    // Reverts if the caller's balance is less than `amount`.
    // Use on partial-redemption paths for a cleaner error message.
    modifier sufficientMintBalance(uint256 amount) {
        require(
            _records[msg.sender].amount >= amount,
            "MintGuard: redeem amount exceeds minted balance"
        );
        _;
    }

    // ── Abstract hooks (implement these in your protocol) ──────────
 
    // Oracle price of the stablecoin in USD, 1e6 precision.
    function _pegPrice() internal view virtual returns (uint256);
 
    // Current annual interest rate, 1e6 precision.
    function _currentRate() internal view virtual returns (uint256);

    function _recordMint(address minter, uint256 amount) internal {
    require(minter != address(0), "MintGuard: zero address");
 
    MintGuardLib.MintRecord memory updated = MintGuardLib.applyMint(
        _records[minter],
        amount,
        _currentRate(),
        _pegPrice()
    );
 
    _records[minter] = updated;
    emit MintRecorded(minter, amount, updated.amount, updated.weightedRate);
    }
 
    function _recordRedemption(
    address redeemer,
    uint256 amount
    ) internal returns (uint256 interestDue) {
        require(redeemer != address(0), "MintGuard: zero address");
 
        (MintGuardLib.MintRecord memory updated, uint256 due) =
        MintGuardLib.applyRedemption(_records[redeemer], amount, _pegPrice());
 
        _records[redeemer] = updated;
        interestDue = due;
        emit RedemptionRecorded(redeemer, amount, due, updated.amount);
    }

    function isMinter(address a) external view override returns (bool) {
        return _records[a].amount > 0;
    }
    function mintedAmount(address a) external view override returns (uint256) {
        return _records[a].amount;
    }
    function effectiveRate(address a) external view override returns (uint256) {
        return _records[a].weightedRate;
    }
    function storedAccruedInterest(address a) external view override returns (uint256) {
        return _records[a].accumInterest;
    }
    function liveAccruedInterest(address a) external view override returns (uint256) {
        return MintGuardLib.previewAccruedInterest(_records[a], _pegPrice());
    }
 
    // Expose the full record to subclasses for custom logic.
    function _getMintRecord(address a)
        internal view returns (MintGuardLib.MintRecord memory) {
        return _records[a];
    }
}
