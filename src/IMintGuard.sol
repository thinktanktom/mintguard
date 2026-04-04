// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMintGuard {
 
    event MintRecorded(
        address indexed minter,
        uint256 mintAmount,
        uint256 newTotal,
        uint256 weightedRate
    );
 
    event RedemptionRecorded(
        address indexed redeemer,
        uint256 redeemAmount,
        uint256 interestPaid,
        uint256 remaining
    );
    // Returns true only if msg.sender has an active mint record.
    // This is the primary Sybil gate.
    function isMinter(address account) external view returns (bool);
 
    // Principal currently minted, 1e18.
    function mintedAmount(address account) external view returns (uint256);
 
    // Running WAIR, 1e6 (52800 = 5.28%).
    function effectiveRate(address account) external view returns (uint256);
 
    // Stored accumulated interest — does NOT include time since last touch.
    function storedAccruedInterest(address account) external view returns (uint256);
 
    // Live accumulated interest — includes elapsed time, read-only projection.
    function liveAccruedInterest(address account) external view returns (uint256);
 
}
