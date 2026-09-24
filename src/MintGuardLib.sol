//The 1e18 precision on accumInterest falls out naturally from the interest formula: amount[1e18] * pegPrice[1e6] * rate[1e6] * days / (365 * 1e12)
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library MintGuardLib {
 
    struct MintRecord {
        uint256 amount;          // principal minted, 1e18
        uint256 weightedRate;    // running WAIR, 1e6
        uint256 accumInterest;   // accrued interest, 1e18 USD
        uint256 lastTouch;       // block.timestamp of last mint or redeem
    }
    function applyMint(
        MintRecord memory record,
        uint256 mintAmount,
        uint256 currentRate,
        uint256 pegPrice
    ) internal view returns (MintRecord memory updated) {
 
        require(mintAmount > 0,    "MintGuardLib: zero mint");
        require(currentRate > 0,   "MintGuardLib: zero rate");
        require(pegPrice > 0,      "MintGuardLib: zero peg price");
 
        updated = record;
 
        if (record.lastTouch == 0) {
            // First mint for this address
            updated.amount       = mintAmount;
            updated.weightedRate = currentRate;
            updated.accumInterest = 0;
            updated.lastTouch    = block.timestamp;
        } else {
            // Subsequent mint: accrue first, then blend rate, then add principal
            uint256 daysElapsed = _daysElapsed(record.lastTouch);
            updated.accumInterest = _accrueInterest(
            record.accumInterest, record.amount,
            record.weightedRate, pegPrice,
            daysElapsed
        );
        updated.weightedRate = _blendRate(
            record.amount, record.weightedRate,
            mintAmount, currentRate
        );
        updated.amount    = record.amount + mintAmount;
        // Advance by whole days actually accrued, not to block.timestamp:
        // otherwise a sub-day remainder is discarded on every touch, and an
        // address that mints/redeems more than once per day never accrues
        // interest at all.
        updated.lastTouch = record.lastTouch + daysElapsed * 86400;
    }
}

function applyRedemption(
    MintRecord memory record,
    uint256 redeemAmount,
    uint256 pegPrice
) internal view returns (MintRecord memory updated, uint256 interestDue) {
 
    require(redeemAmount > 0,              "MintGuardLib: zero redeem");
    require(record.lastTouch > 0,          "MintGuardLib: no mint record");
    require(redeemAmount <= record.amount, "MintGuardLib: over-redemption");
    require(pegPrice > 0,                  "MintGuardLib: zero peg price");
 
    updated = record;

    // 1. Accrue to now
    uint256 daysElapsed = _daysElapsed(record.lastTouch);
    updated.accumInterest = _accrueInterest(
        record.accumInterest, record.amount,
        record.weightedRate, pegPrice,
        daysElapsed
    );

    // 2. Pro-rata slice
    interestDue = (redeemAmount * updated.accumInterest) / record.amount;

    // 3. Deduct and reduce principal
    updated.accumInterest = updated.accumInterest - interestDue;
    updated.amount        = record.amount - redeemAmount;
    // See applyMint: advance by whole days actually accrued, not to
    // block.timestamp, so a sub-day remainder carries into the next accrual
    // instead of being discarded.
    updated.lastTouch     = record.lastTouch + daysElapsed * 86400;
}

// Mirrors: accum + (amount * pegPrice * rate * days) / (365 * 1e12)
function _accrueInterest(
    uint256 accumInterest, uint256 amount,
    uint256 rate, uint256 pegPrice, uint256 daysElapsed
) private pure returns (uint256) {
    if (daysElapsed == 0 || amount == 0 || rate == 0) return accumInterest;
    return accumInterest + (amount * pegPrice * rate * daysElapsed) / (365 * 1e12);
}
 
// Mirrors: (oldPrincipal * oldRate + newAmount * newRate) / totalPrincipal
function _blendRate(
    uint256 oldPrincipal, uint256 oldRate,
    uint256 newAmount,    uint256 newRate
) private pure returns (uint256) {
    return ((oldPrincipal * oldRate) + (newAmount * newRate))
        / (oldPrincipal + newAmount);
}
 
// Mirrors: delta_t = (block.timestamp - time) / 86400
function _daysElapsed(uint256 lastTouch) private view returns (uint256) {
    if (block.timestamp <= lastTouch) return 0;
    return (block.timestamp - lastTouch) / 86400;
}

function previewAccruedInterest(
    MintRecord memory record,
    uint256 pegPrice
) internal view returns (uint256) {
    if (record.lastTouch == 0 || record.amount == 0) return 0;
    return _accrueInterest(
        record.accumInterest, record.amount,
        record.weightedRate, pegPrice,
        _daysElapsed(record.lastTouch)
    );
}
}
