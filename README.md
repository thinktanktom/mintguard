# MintGuard

**Sybil-resistant minting and weighted-average interest accounting for Solidity.**

Derived from a security pattern first deployed in the [BankX Protocol](https://bankx.io) to solve the *two-wallet minting Sybil attack*.

---

## The Problem

Any protocol that issues a stablecoin against collateral **and** pays interest to minters tracked by wallet address is vulnerable to this attack:

```
Step 1  Wallet A mints stablecoin.
        Interest counter starts on Wallet A.

Step 2  Wallet A transfers stablecoin to Wallet B.
        Wallet B is a fresh address with no mint record.

Step 3  Wallet B redeems collateral.
        The protocol has no record for B, so it cannot
        stop Wallet A's interest counter.

Step 4  Wallet A redeems later, collecting interest on
        collateral that was already redeemed by Wallet B.

Step 5  Repeat. Drain reward tokens indefinitely.
```

This attack was documented and solved during the construction of BankX Protocol. From the original whitepaper:

> *"Since we store the wallet address for each minter so that we can track the interest owed, this exposes the system to Sybil attacks. A minter could create two wallets, minting with one and moving the XSD to the other wallet to redeem their collateral."*
>
> — BankX Whitepaper, "Minting Sybil Attacks" — https://bankx.io/whitepaper

---

## The Fix

Bind the right to redeem collateral to the wallet that minted. Four fields stored per address make this binding enforced and auditable on-chain.

```
┌─────────────────────────────────────────────────────────────┐
│  MintRecord { amount, weightedRate, accumInterest, lastTouch }
│  stored per address                                          │
└─────────────────────────────────────────────────────────────┘

mint(Wallet A, amount)    →  record created on A
redeem(Wallet B, amount)  →  REVERT — B has no mint record
redeem(Wallet A, amount)  →  OK, proportional interest returned
```

---

## Installation

```bash
forge install your-org/mintguard
```

Add to `remappings.txt`:

```
mintguard/=lib/mintguard/src/
```

---

## Integration

Implement two hooks. Call two functions. Apply one modifier. That is the entire API.

```solidity
import "mintguard/MintGuard.sol";

contract MyStablecoin is MintGuard {

    // 1. Provide your oracle price (6 decimals — $1.00 = 1_000_000)
    function _pegPrice() internal view override returns (uint256) {
        return oracle.latestPrice();
    }

    // 2. Provide your protocol's current annual interest rate (6 decimals)
    //    52_800 = 5.28% p.a.
    function _currentRate() internal view override returns (uint256) {
        return pidController.interest_rate();
    }

    // 3. Record every mint
    function mint(uint256 amount) external payable {
        // ... collateral validation ...
        _recordMint(msg.sender, amount);
        stablecoin.mint(msg.sender, amount);
    }

    // 4. Guard every redemption with onlyMinter
    function redeem(uint256 amount) external onlyMinter {
        uint256 interestDue = _recordRedemption(msg.sender, amount);
        // pay interestDue (1e12 USD units) as reward tokens
        stablecoin.burn(msg.sender, amount);
        collateral.transfer(msg.sender, amount);
    }
}
```

---

## File Structure

```
src/
  MintGuardLib.sol    Pure math library. No oracle dependencies.
                      Portable to any EVM chain. Vendorable standalone.

  IMintGuard.sol      Interface for external tooling and analytics.
                      Two events, five view functions.

  MintGuard.sol       Abstract contract. Inherit and implement two hooks.

test/
  MintGuard.t.sol     Foundry test suite. 20 tests across 6 sections.
                      Includes test_SybilAttack_TwoWalletDrain.
```

---

## Tests

```bash
# Run everything
forge test -vv

# The canonical Sybil attack proof
forge test --match-test test_SybilAttack_TwoWalletDrain -vvv

# Fuzz invariants with high iteration count
forge test --match-test testFuzz --fuzz-runs 10000
```

### What the test suite covers

| Section | Tests |
|---|---|
| 1. Basic state | First mint initialises correctly. `isMinter` gate. Balance accumulation. |
| 2. WAIR | Blend formula correct. Fuzz: WAIR never escapes `[min_rate, max_rate]`. |
| 3. Interest accrual | Zero on first mint. Correct after one year. Monotonically non-decreasing. `live > stored` after time passes. |
| 4. Redemption | Full redemption clears record. Partial pays proportional interest. Remaining position keeps accruing. Over-redemption reverts. |
| **5. Sybil attack** | **`test_SybilAttack_TwoWalletDrain` — Bob cannot redeem. Alice's record unaffected. Alice redeems normally.** |
| 6. Fuzz invariants | Sum of partial redemptions equals total accrued. WAIR bounded across three-mint sequences. |

---

## Precision Reference

| Variable | Unit | Example | Notes |
|---|---|---|---|
| `amount` | tokens, 1e18 | `1e18` = 1 token | Standard ERC-20 |
| `pegPrice` | USD, 1e6 | `980_000` = $0.98 | From your oracle |
| `rate` | annual %, 1e6 | `52_800` = 5.28% | From your PID controller |
| `accumInterest` | USD, 1e12 | `1e12` = $1.00 | Output of interest formula |

**Interest formula** (mirrors `CollateralPoolLibrary.calcMintInterest` exactly):

```
newAccum = oldAccum + (amount × pegPrice × rate × daysElapsed) / (365 × 1e12)
```

**Weighted rate blend** (mirrors `TreasuryPool._calculateWeightedRate`):

```
newRate = (oldPrincipal × oldRate + newAmount × newRate) / (oldPrincipal + newAmount)
```

---

## Attribution

This pattern was developed by the BankX team and first deployed in production in `CollateralPool.sol` and `CollateralPoolLibrary.sol`.

The original problem statement is in the BankX whitepaper under **"Minting Sybil Attacks"**: https://bankx.io/whitepaper

If you use MintGuard in your protocol, please attribute it:

```solidity
// Sybil-resistance pattern: github.com/your-org/mintguard
// Origin: BankX Protocol — https://bankx.io
```

---

## License

MIT
