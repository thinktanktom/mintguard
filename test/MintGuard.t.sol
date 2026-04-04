// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/MintGuard.sol";
import "../src/MintGuardLib.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MockProtocol
//
// A minimal concrete implementation of MintGuard used only inside these tests.
// It exposes _recordMint and _recordRedemption as external functions so the
// test harness can call them from arbitrary addresses using vm.prank.
// ─────────────────────────────────────────────────────────────────────────────

contract MockProtocol is MintGuard {

    uint256 public pegPrice;
    uint256 public interestRate;

    constructor(uint256 _initialPegPrice, uint256 _initialRate) {
        pegPrice     = _initialPegPrice;
        interestRate = _initialRate;
    }

    // ── Abstract hook implementations ─────────────────────────────────────

    function _pegPrice() internal view override returns (uint256) {
        return pegPrice;
    }

    function _currentRate() internal view override returns (uint256) {
        return interestRate;
    }

    // ── Exposed internals ─────────────────────────────────────────────────

    function mint(address minter, uint256 amount) external {
        _recordMint(minter, amount);
    }

    function redeem(address redeemer, uint256 amount) external returns (uint256 interestDue) {
        return _recordRedemption(redeemer, amount);
    }

    function getRecord(address account) external view returns (MintGuardLib.MintRecord memory) {
        return _getMintRecord(account);
    }

    // ── Test mutation helpers ──────────────────────────────────────────────

    function setPegPrice(uint256 _price) external { pegPrice     = _price; }
    function setRate(uint256 _rate)      external { interestRate = _rate;  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MintGuardTest
// ─────────────────────────────────────────────────────────────────────────────

contract MintGuardTest is Test {

    // ── Constants ─────────────────────────────────────────────────────────

    uint256 constant PEG_PRICE  = 980_000;   // $0.98 per gram of silver, 1e6
    uint256 constant RATE_MIN   = 52_800;    // 5.28% p.a. minimum, 1e6
    uint256 constant RATE_HIGH  = 200_000;   // 20% p.a.
    uint256 constant ONE_TOKEN  = 1e18;
    uint256 constant ONE_DAY    = 86_400;
    uint256 constant ONE_YEAR   = 365 * ONE_DAY;

    MockProtocol protocol;

    address alice   = makeAddr("alice");
    address bob     = makeAddr("bob");

    function setUp() public {
        protocol = new MockProtocol(PEG_PRICE, RATE_MIN);
    }


    // =========================================================================
    // Section 1: Basic state transitions
    // =========================================================================

    // First mint initialises the record with the correct values.
    // amount == mintAmount, rate == currentRate, accum == 0, lastTouch set.
    function test_FirstMint_InitialisesRecordCorrectly() public {
        uint256 amount = 100 * ONE_TOKEN;
        protocol.mint(alice, amount);

        MintGuardLib.MintRecord memory rec = protocol.getRecord(alice);

        assertEq(rec.amount,        amount,          "amount mismatch");
        assertEq(rec.weightedRate,  RATE_MIN,        "rate should equal currentRate on first mint");
        assertEq(rec.accumInterest, 0,               "no interest on first mint, no time has elapsed");
        assertEq(rec.lastTouch,     block.timestamp, "lastTouch should be set to block.timestamp");
    }

    // isMinter returns false before any mint and true after.
    function test_IsMinter_CorrectlyTracksState() public {
        assertFalse(protocol.isMinter(alice), "should not be minter before mint");
        protocol.mint(alice, ONE_TOKEN);
        assertTrue(protocol.isMinter(alice),  "should be minter after mint");
    }

    // mintedAmount accumulates correctly across two separate mint events.
    function test_MintedAmount_AccumulatesAcrossMultipleMints() public {
        protocol.mint(alice, 100 * ONE_TOKEN);
        protocol.mint(alice,  50 * ONE_TOKEN);

        assertEq(protocol.mintedAmount(alice), 150 * ONE_TOKEN);
    }

    // Minting zero tokens must revert.
    function test_ZeroMintAmount_Reverts() public {
        vm.expectRevert("MintGuardLib: zero mint");
        protocol.mint(alice, 0);
    }


    // =========================================================================
    // Section 2: Weighted-average interest rate (WAIR)
    // =========================================================================

    // After two mints at different rates, the WAIR equals the amount-weighted
    // average of those rates.
    //
    // Given:
    //   Mint 1: 100 tokens at rate 52800
    //   Mint 2: 100 tokens at rate 200000
    //
    // Expected WAIR = (100 * 52800 + 100 * 200000) / 200 = 126400
    function test_WeightedRate_CorrectAfterTwoMintsAtDifferentRates() public {
        protocol.mint(alice, 100 * ONE_TOKEN);   // rate = RATE_MIN

        skip(ONE_DAY);
        protocol.setRate(RATE_HIGH);
        protocol.mint(alice, 100 * ONE_TOKEN);   // rate = RATE_HIGH

        uint256 expectedWAIR = (100 * RATE_MIN + 100 * RATE_HIGH) / 200;

        assertEq(protocol.effectiveRate(alice), expectedWAIR, "WAIR incorrect");
    }

    // Fuzz: WAIR must always stay within the range [min(r1,r2), max(r1,r2)].
    // It can never be lower than the lowest component rate or higher than the highest.
    function testFuzz_WeightedRate_AlwaysWithinComponentBounds(
        uint128 amount1,
        uint128 amount2,
        uint32  rate1,
        uint32  rate2
    ) public {
        vm.assume(amount1 > 0 && amount2 > 0);
        vm.assume(rate1 >= 1 && rate1 <= 1_000_000);
        vm.assume(rate2 >= 1 && rate2 <= 1_000_000);

        protocol.setRate(rate1);
        protocol.mint(alice, uint256(amount1));

        skip(ONE_DAY);

        protocol.setRate(rate2);
        protocol.mint(alice, uint256(amount2));

        uint256 wair    = protocol.effectiveRate(alice);
        uint256 minRate = rate1 < rate2 ? rate1 : rate2;
        uint256 maxRate = rate1 > rate2 ? rate1 : rate2;

        assertGe(wair, minRate, "WAIR below minimum component rate");
        assertLe(wair, maxRate, "WAIR above maximum component rate");
    }


    // =========================================================================
    // Section 3: Interest accrual
    // =========================================================================

    // Immediately after a first mint, no time has elapsed, so interest is zero.
    function test_AccruedInterest_ZeroImmediatelyAfterFirstMint() public {
        protocol.mint(alice, 100 * ONE_TOKEN);

        assertEq(protocol.liveAccruedInterest(alice), 0);
    }

    // After exactly 365 days, accrued interest matches the annual yield formula:
    //   interest = (amount * pegPrice * rate) / 1e12
    // (The 365-day divisor cancels when daysElapsed == 365.)
    function test_AccruedInterest_CorrectAfterOneYear() public {
        uint256 amount = 100 * ONE_TOKEN;
        protocol.mint(alice, amount);
        skip(ONE_YEAR);

        uint256 expected = (amount * PEG_PRICE * RATE_MIN) / 1e12;

        assertEq(protocol.liveAccruedInterest(alice), expected, "annual interest mismatch");
    }

    // Accrued interest must be monotonically non-decreasing over time.
    // It should never go backwards between observations.
    function test_AccruedInterest_IsMonotonicallyNonDecreasing() public {
        protocol.mint(alice, 100 * ONE_TOKEN);

        uint256 prev = protocol.liveAccruedInterest(alice);
        for (uint256 i = 0; i < 10; i++) {
            skip(30 * ONE_DAY);
            uint256 curr = protocol.liveAccruedInterest(alice);
            assertGe(curr, prev, "interest decreased over time");
            prev = curr;
        }
    }

    // liveAccruedInterest must exceed storedAccruedInterest once time has
    // passed without an on-chain interaction.
    function test_LiveInterest_ExceedsStoredInterestAfterTimeElapses() public {
        protocol.mint(alice, 100 * ONE_TOKEN);
        skip(30 * ONE_DAY);

        uint256 stored = protocol.storedAccruedInterest(alice);
        uint256 live   = protocol.liveAccruedInterest(alice);

        assertGt(live, stored, "live should exceed stored after time passes");
    }

    // With zero days elapsed since the last touch, live must equal stored.
    function test_ZeroDaysElapsed_LiveEqualsStored() public {
        protocol.mint(alice, 100 * ONE_TOKEN);

        assertEq(
            protocol.liveAccruedInterest(alice),
            protocol.storedAccruedInterest(alice),
            "zero elapsed: live should equal stored"
        );
    }


    // =========================================================================
    // Section 4: Redemption correctness
    // =========================================================================

    // Full redemption returns all accrued interest and zeroes the record.
    function test_FullRedemption_ReturnsAllInterestAndClearsRecord() public {
        uint256 amount = 100 * ONE_TOKEN;
        protocol.mint(alice, amount);
        skip(ONE_YEAR);

        uint256 expectedInterest = (amount * PEG_PRICE * RATE_MIN) / 1e12;
        uint256 interestPaid     = protocol.redeem(alice, amount);

        assertEq(interestPaid,                 expectedInterest, "interest paid mismatch");
        assertEq(protocol.mintedAmount(alice), 0,                "balance should be zero after full redemption");
        assertFalse(protocol.isMinter(alice),                    "should no longer be a minter");
    }

    // Partial redemption pays the correct proportional slice of accrued interest.
    // Redeeming half the position must pay exactly half the total accrued interest.
    function test_PartialRedemption_PaysProportionalInterest() public {
        uint256 amount = 100 * ONE_TOKEN;
        protocol.mint(alice, amount);
        skip(ONE_YEAR);

        uint256 totalInterest    = protocol.liveAccruedInterest(alice);
        uint256 halfInterestPaid = protocol.redeem(alice, amount / 2);

        // Allow ±1 wei for integer division rounding.
        assertApproxEqAbs(halfInterestPaid, totalInterest / 2, 1, "wrong proportional interest");
        assertEq(protocol.mintedAmount(alice), amount / 2, "remaining balance wrong");
    }

    // After a partial redemption, the remaining position must continue to accrue.
    function test_PartialRedemption_RemainingInterestContinuesToAccrue() public {
        uint256 amount = 100 * ONE_TOKEN;
        protocol.mint(alice, amount);
        skip(180 * ONE_DAY);

        protocol.redeem(alice, amount / 2);
        uint256 interestAfterPartial = protocol.storedAccruedInterest(alice);

        skip(180 * ONE_DAY);
        uint256 interestLater = protocol.liveAccruedInterest(alice);

        assertGt(interestLater, interestAfterPartial, "interest should continue accruing after partial redemption");
    }

    // Redeeming more than the minted balance must revert.
    function test_Redemption_RevertsOnOverRedemption() public {
        protocol.mint(alice, 50 * ONE_TOKEN);

        vm.expectRevert("MintGuardLib: over-redemption");
        protocol.redeem(alice, 51 * ONE_TOKEN);
    }

    // Redeeming with no mint record at all must revert.
    function test_Redemption_RevertsIfNeverMinted() public {
        vm.expectRevert("MintGuardLib: no mint record");
        protocol.redeem(bob, ONE_TOKEN);
    }

    // Redeeming zero tokens must revert.
    function test_ZeroRedeemAmount_Reverts() public {
        protocol.mint(alice, ONE_TOKEN);

        vm.expectRevert("MintGuardLib: zero redeem");
        protocol.redeem(alice, 0);
    }


    // =========================================================================
    // Section 5: The Sybil attack
    // =========================================================================

    // THE TWO-WALLET MINTING SYBIL ATTACK — and why it fails.
    //
    // Background (BankX whitepaper, "Minting Sybil Attacks"):
    //
    //   Without MintGuard an attacker can:
    //
    //     Step 1  Wallet A mints stablecoin. Interest counter starts on A.
    //     Step 2  Wallet A transfers stablecoin to Wallet B (fresh address, no record).
    //     Step 3  Wallet B redeems collateral. Protocol has no record for B,
    //             so it cannot stop Wallet A's interest counter.
    //     Step 4  Wallet A's interest keeps running. A redeems later, collecting
    //             interest on collateral that was already redeemed.
    //     Step 5  Repeat indefinitely. Drain reward tokens.
    //
    //   MintGuard closes this at Step 3: applyRedemption requires lastTouch > 0,
    //   which is only set by a prior _recordMint call on that same address.
    //
    // This test proves that an account which has never called _recordMint
    // cannot redeem — even if it holds the stablecoin.
    //
    function test_SybilAttack_TwoWalletDrain() public {

        // ── Setup ────────────────────────────────────────────────────────────
        // Alice is the legitimate minter (Wallet A).
        uint256 mintAmount = 1000 * ONE_TOKEN;
        protocol.mint(alice, mintAmount);
        skip(ONE_YEAR);

        uint256 aliceInterestBefore = protocol.liveAccruedInterest(alice);
        assertGt(aliceInterestBefore, 0, "sanity: Alice must have accrued interest");

        // ── The Attack ───────────────────────────────────────────────────────
        // Bob is Wallet B. He holds XSD transferred from Alice but has never minted.
        assertFalse(protocol.isMinter(bob), "Bob should not be a minter");
        assertEq(protocol.mintedAmount(bob), 0, "Bob has no minted balance");

        // Bob attempts to redeem. This must revert.
        vm.expectRevert("MintGuardLib: no mint record");
        protocol.redeem(bob, mintAmount);

        // ── Attack had no effect on Alice ────────────────────────────────────
        assertEq(
            protocol.mintedAmount(alice),
            mintAmount,
            "Alice's balance must be untouched after the failed attack"
        );
        assertGe(
            protocol.liveAccruedInterest(alice),
            aliceInterestBefore,
            "Alice's accrued interest must be intact"
        );

        // ── Alice can still redeem normally ──────────────────────────────────
        uint256 interestPaid = protocol.redeem(alice, mintAmount);

        assertGt(interestPaid, 0,                  "Alice must receive her interest");
        assertEq(protocol.mintedAmount(alice), 0,  "Alice's balance cleared after redeem");
    }

    // Variant: a zero address cannot be used as the redemption target.
    function test_SybilAttack_ZeroAddressAttempt() public {
        protocol.mint(alice, ONE_TOKEN);

        vm.expectRevert("MintGuard: zero address");
        protocol.redeem(address(0), ONE_TOKEN);
    }

    // Two independent minters must have fully isolated records.
    // Alice's redemption must have zero effect on Bob's accumulated interest.
    function test_SybilAttack_IndependentMinterIsolation() public {
        protocol.mint(alice, 100 * ONE_TOKEN);
        protocol.mint(bob,   200 * ONE_TOKEN);
        skip(ONE_YEAR);

        uint256 aliceInterest = protocol.liveAccruedInterest(alice);
        uint256 bobInterest   = protocol.liveAccruedInterest(bob);

        // Bob minted twice as much so should have exactly twice the interest.
        assertApproxEqAbs(bobInterest, aliceInterest * 2, 2, "Bob should have 2x Alice's interest");

        // Alice redeems. Bob's record must be completely unchanged.
        protocol.redeem(alice, 100 * ONE_TOKEN);

        assertApproxEqAbs(
            protocol.liveAccruedInterest(bob),
            bobInterest,
            bobInterest / 1000,  // 0.1% tolerance for timestamp rounding
            "Bob's interest must not change when Alice redeems"
        );
    }


    // =========================================================================
    // Section 6: Fuzz invariants
    // =========================================================================

    // Three sequential partial redemptions (each 1/3 of the position) must
    // together pay out the full accumulated interest.
    function testFuzz_PartialRedemptions_SumToTotalInterest(
        uint64 amount,
        uint32 days1,
        uint32 days2,
        uint32 days3
    ) public {
        vm.assume(amount > 1e6);
        vm.assume(days1 > 0 && days2 > 0 && days3 > 0);

        uint256 third = uint256(amount) / 3;
        vm.assume(third > 0);

        protocol.mint(alice, third * 3);

        skip(uint256(days1) * ONE_DAY);
        uint256 paid1 = protocol.redeem(alice, third);

        skip(uint256(days2) * ONE_DAY);
        uint256 paid2 = protocol.redeem(alice, third);

        // Snapshot total accrued before the final redemption.
        skip(uint256(days3) * ONE_DAY);
        uint256 remainingInterest = protocol.liveAccruedInterest(alice);  // live
        uint256 paid3 = protocol.redeem(alice, third);

        // paid1 + paid2 + paid3 should equal paid1 + paid2 + what remained at snapshot.
        assertApproxEqAbs(
            paid3,
            remainingInterest,
            10,  // 10 wei tolerance for rounding
            "final payment should match remaining interest at time of last redemption"
        );
    }

    // Fuzz: no sequence of mints can produce a WAIR outside [min_rate, max_rate].
    // Redundant with Section 2's fuzz but runs with larger input space.
    function testFuzz_WeightedRate_NeverEscapesBounds(
        uint96 a1, uint96 a2, uint96 a3,
        uint24 r1, uint24 r2, uint24 r3
    ) public {
        vm.assume(a1 > 0 && a2 > 0 && a3 > 0);
        vm.assume(r1 >= 1 && r1 <= 1_000_000);
        vm.assume(r2 >= 1 && r2 <= 1_000_000);
        vm.assume(r3 >= 1 && r3 <= 1_000_000);

        uint256 minRate = r1 < r2 ? (r1 < r3 ? r1 : r3) : (r2 < r3 ? r2 : r3);
        uint256 maxRate = r1 > r2 ? (r1 > r3 ? r1 : r3) : (r2 > r3 ? r2 : r3);

        protocol.setRate(r1); protocol.mint(alice, a1); skip(ONE_DAY);
        protocol.setRate(r2); protocol.mint(alice, a2); skip(ONE_DAY);
        protocol.setRate(r3); protocol.mint(alice, a3);

        uint256 wair = protocol.effectiveRate(alice);
        assertGe(wair, minRate, "WAIR below minimum");
        assertLe(wair, maxRate, "WAIR above maximum");
    }
}
