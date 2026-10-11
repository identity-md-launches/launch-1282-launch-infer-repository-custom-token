# Test-only contribution

This contribution leaves the incoming contracts, root `ADAPTATION.md`, launch economics,
configuration and vendored libraries unchanged. All delivered additions are under `test/`.
The existing launch rehearsal and earlier regression tests remain intact.

Added failure-path tests use the launch's exact allocations, rates, treasury, governor and
founder. Burnable local tokens stand in for external MIYA/MXXN only when testing redemption
accounting and atomic rollback. The existing mainnet tests remain the check for the real
NFT whitelist and moon-window behavior. A test-only SeasonVault subclass substitutes an
attestation signer so valid signatures can be generated locally; a separate test confirms
that the production SeasonVault refuses that signer.

The supplied Pashov and Trail of Bits property-testing references informed property selection.
The tests are written for this repository and use only its existing forge-std and OpenZeppelin
dependencies. No downloads, additional tooling, environment-variable mutation, configuration changes,
or production adaptations are required to run the local tests.

## Failure paths and boundaries

- Legacy redemption: zero/unsupported/dust inputs; exact allocation and closing boundaries;
  missing approvals and balances; failed transfers and burns, including rollback of an
  automatic vested payout and allowance consumption; independent token caps; upkeep rollback;
  partitioned redemptions and final settlement at the exact launch rates.
- Seasons: authorization for every governor entry point; missing seasons, roots and proposals;
  replacement/cancellation of proposals; exact root/end/registration deadlines; irreversible
  program end; proof binding; duplicate registration; atomic batch rollback; preservation of
  registered claims through expiry and treasury sweeps.
- Attestations: production signer rejection of fixture signatures; consumer/chain domain
  separation; tampered signed fields; panel/answer/time/window checks; malformed signatures,
  high-s malleability and invalid recovery; replay protection; rollback of request consumption
  when downstream root validation fails; invalid CIDs.
- Launch/token/staking/founder: rejected constructor arguments; absence of administrative,
  mint and burn entry points; full-supply transfer and maximum-input failure; deposit/exit
  rollback; unauthorized withdrawals; the one-block hold; exact founder cliff/end, delayed
  funding and release-frequency independence.

## Stateful properties

Each `invariant/` suite targets an explicit list of handler selectors and sets
`fail-on-revert = true` in source. Expected failures use exact revert expectations.
Amounts are bounded to balances and allocations; actors are a finite tracked set.
The outer invariant sender is the local test contract, avoiding unrelated RPC account reads
on a fork; protocol calls still use the handler's distinct actors and fixed launch roles.
Production INFER is funded through ordinary transfers, never token balance/storage cheatcodes.

| Suite | Random actions | Independently checked properties |
| --- | --- | --- |
| Token | transfer, approve, transferFrom, insufficient balance/allowance, zero receiver | fixed supply; exact actor balances; finite/infinite allowance ledger; no fees or burns |
| Legacy | both legacy redemptions, claims, time, donations, clock upkeep, sweep | earned = received + vesting debt for every wallet; global debt backed by INFER; burns match inputs; allocations/caps remain separate; funded = held + paid + swept |
| Season | opening, proposals/replacements/withdrawals, applying roots, direct/batched claims, releases, expiry, end/cancel/sweep, time, donations | reserves equal open pots plus unpaid obligations; per-season totals and entitlements match the independent model; no duplicate payouts; no overlapping seasons; ended state cannot reopen; treasury and claimant payments conserve funding |
| Staking/dripper | deposits, mints, delegated exits/transfers, donations, drips, time/blocks, repeated round trips, unauthorized exits | all shares accounted for and backed; virtual-adjusted share value cannot decrease; held shares cannot be shed or extended by transfers; rewards and keeper fees conserve buffer funding; repeated cycles create no INFER |
| Founder | funding, time, permissionless releases by several callers | only the beneficiary receives value; funded = held + released; no pre-cliff payout or excess early payout; late donations recoverable after maturity |
| Splitter | two independent launches, donations/top-ups, splits, sweeps by several callers | exact one-time bucket allocations; atomic rollback while underfunded; no cross-token payments; late deposits go to the fixed treasury; conservation per launch |

Every suite runs 256 sequences. Depth is 96 except the splitter's 64, totaling 139,264
randomized handler calls per complete run, in addition to terminal checks. Legacy, season,
staking, founder and splitter suites finish each sequence by moving forward to the applicable
maturity/deadline and actually settling all remaining claims or shares. This checks that
accounting remains usable, rather than merely internally consistent. Stateless arithmetic
properties run 1,000 cases; attestation mutation properties run 256 cases each.

## Scope of evidence

The local season model constructs valid four-leaf allocations and exercises the governor
fallback path. Signature failure tests and the incoming suite cover the attested path;
the independent model does not calculate the off-chain points formula or establish the
correctness of a real panel's judgment. Local legacy fixtures do not prove external token
liveness; the fork suite exercises those dependencies. Random call sequences are bounded
campaigns, not a proof over all possible inputs.

Run `forge build` and `forge test` without any RPC. To include the existing live factory,
splitter and legacy-token rehearsal, use `forge test --fork-url <mainnet RPC URL>`.

## Verification of this contribution

- `forge build`: passed with the repository's existing compiler/configuration. Foundry lint
  warnings remain; no compiler errors.
- `forge test`: 116 passed, 0 failed, 2 fork-only suite setups skipped.
- `forge test --fork-url https://ethereum-rpc.publicnode.com`: 120 passed, 0 failed,
  0 skipped. Includes all six invariant suites, real MIYA/MXXN behavior, and the live
  ProjectFactory/GenesisSplitter launch rehearsal.
- The separately observed mainnet launch rehearsal at block 26,167,021 used 8,891,274 gas
  inside `launchCustom` and paid all three declared genesis allocations.
- Every invariant suite completed its configured sequences with zero unexpected handler
  reverts. Final local runtime was approximately 47 seconds; the full fork run took
  approximately 119 seconds with the public endpoint.
- Scope check: only new files under `test/`; incoming source, tests, root documentation,
  libraries and configuration have no tracked changes. `git diff --check` passed.

No additional implementation defect was reproduced by this contribution. No production
behavior was changed or asserted as correct to bypass a failing property.

## Revision: retain coverage after the accepted contract fixes

The sections above record the preceding test contribution. On this revision's incoming tree,
`forge test` reported 129 passed, four failed and two fork-only setups skipped. The failures
were stale test expectations or fixtures following the accepted production fixes documented
in the root `ADAPTATION.md`. This revision changes only the affected tests and their handlers;
all six conservation invariants, their run counts and `fail-on-revert = true` remain in place.

- `SeasonFailurePaths.t.sol`: create a pending proposal early enough to mature strictly before
  the root deadline, then check that it cannot be applied at that deadline and expiry clears
  it. A registered claimant must now receive its stored entitlement at/after the registration
  deadline. A separate valid, unregistered leaf is rejected at the deadline and after expiry,
  while the registered debt remains backed and payable.
- `SeasonAccounting.invariant.t.sol`: late proposals/replacements and late applications now
  expect `PastDeadline` without changing the model. Random direct and batch claims continue
  for registered accounts after the deadline/expiry, while new registrations explicitly fail.
  Terminal settlement also exercises both claim routes after expiry. Two deterministic
  sequences retain coverage of pending-proposal preservation and late claimant settlement.
- `LegacyAccounting.invariant.t.sol`: replace only the MXXN fixture with a burnable token
  exposing `moonConfig()` and advancing one cycle per overdue transfer/burn. Time advancement
  also advances blocks. Track upkeep donations and burns separately from redemption inputs,
  including unused dust retained when the clock is current. Assert both token supply and
  the redeemer's dust balance against those independent totals. A deterministic sequence
  checks the inclusive window end, partial catch-up, stopping when current, and zero steps.
  This simplified fixture does not simulate MXXN's transfer gating; the existing real-token
  fork tests continue to cover that dependency.
- `StakingAccounting.invariant.t.sol`: use the accepted minimum of `1e9` raw real shares when
  predicting the dripper's refusal, and check keeper balances are also unchanged on failure.
  A deterministic sequence redeems the initial stake, mints just below the threshold, reaches
  it, withdraws below it and replenishes it, checking rejected and successful drips throughout.

These are test corrections for the accepted fixes, not assertions blessing a newly discovered
defect. No additional production defect was reproduced. No production source, configuration,
dependency, allocation, rate, recipient, schedule or token behavior was changed. No new
dependencies, environment mutations or network access are required for the local suite.

Revision verification:

- `forge build`: passed; existing lint warnings remain.
- `forge test`: 138 passed, zero failed, two fork-only setups skipped.
- `forge test --fork-url https://ethereum-rpc.publicnode.com -vv`: 142 passed, zero failed,
  zero skipped, including the live ProjectFactory/GenesisSplitter and real MIYA/MXXN tests.
- All six invariant suites run 256 sequences at their existing depths, totaling 139,264
  randomized handler calls, plus terminal settlement, with zero unexpected handler reverts.
- Only five existing files under `test/` changed; `git diff --check` passed.
