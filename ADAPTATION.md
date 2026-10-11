# INFER launch adaptation

The sections through "Mainnet rehearsal and verification" record the previously accepted round.
The revision review and its additional changes are recorded at the end of this document.

## Scope and unchanged terms

Reviewed the supplied custom-token protected tests and security reference, then all seven source
contracts, the inherited OpenZeppelin vault implementation, GenesisSplitter and the existing tests.
The incoming suite passed: 54 local tests with the two fork suites skipped; 58 tests on mainnet.
The imported proofs were then run against the unchanged contracts in scratch tests. All three
failed with their reported defects. Additional tests reproduced the unbounded season start and
the staking constructor's external metadata call. The existing mainnet MIYA/MXXN tests reproduced
the operational prerequisites. No imported finding was rejected as non-reproducible.

`InferToken`, `LegacyRedeemer`, `FounderStream` and `SeasonAttestation` source are unchanged.
INFER remains the specified ownerless, ordinary 18-decimal ERC-20, with exactly
`1000000000000000000000000000` units minted once to its constructor caller and no later mint/burn.
All application constructor signatures, allocations, rates and recipients remain the specified ones.
The 365-day redemption period, 13-week vesting/seasons, 30-day founder cliff, 365-day founder stream,
48-hour notices/root delay and 26-week deadlines are unchanged. The only timing-related corrections
are the reproduced future-start bound and dripper liveness exception described below.

No owner, pause, upgrade, token fee or new mint authority was added. Build configuration and vendored
dependencies are unchanged. No packages were installed. No transactions were broadcast. The subsequent
manifest step writes `launch.json`; the exact economics and pool terms are recorded in `README.md`
and exercised by the launch rehearsal.

## Changes required by the reproduced findings

### Season registrations exceeding their root total — medium

Finding `aee37e82cc12bba90aa49184d6908a63c8d87487c93ab40152784d1afc3d7441` reproduced:
the supplied 150M-INFER leaf under a 1-INFER declared total was accepted despite another season's
210M reserve. It should have reverted. This also permits `registered > total`, making expiry underflow.

In `src/SeasonVault.sol`, `_register` now rejects an amount above `total - registered` before changing
the entitlement or reserves. Subtraction avoids overflowing a proposed sum. The bound applies to
governor and attested roots and to batch distribution. Payments do not restore registration capacity;
repeat registration of an existing entitlement remains idempotent.

`test/Buckets.t.sol` adds the exact single-leaf governor reproduction, an attested cumulative oversubscription
after a prior payment, atomic rollback of an oversubscribed batch, and a fuzz test of registration,
expiry, release and reserve conservation. Expiry succeeds and other seasons' reserves remain intact.

### Dust deposits blocking another holder's exit — medium

Finding `b45095aca81c2837ff36ac9dc7636de35ab7ca79b16ac59fad98f7d2ce8253b0` reproduced:
a stranger depositing 1 wei for Alice made all her previously matured shares non-redeemable that block.

In `src/StakedInfer.sol`, the one-block hold now counts only the shares received with an active hold.
Every mint is held, including third-party deposits/mints; transfers spend unlocked shares first and
carry any held part to the receiver. Receiving held dust cannot hold older shares. Self/zero transfers
cannot refresh or discard a hold. `maxRedeem` exposes the unlocked balance, inherited `maxWithdraw`
converts it with the original rounding, and the withdrawal guard enforces that same balance.
`lastDepositBlock` is retained; `lockedShares(account)` reports the shares still held in that block.

`test/StakingRegression.t.sol` tests the supplied attack, mint/withdraw and approved-operator paths,
fresh deposits to another receiver, transfers of freshly minted dust, partial transfers, self/zero
transfers, expiry/reset of holds and fuzzed conservation of held and unlocked shares. It also checks
that the fix cannot enable a same-block exit through another receiver. Existing inflation and
deposit/drip sandwich tests continue to pass.

### Small dripper buffers permanently stranded — medium

Finding `75c201f593549b5be6afa80ff630a9f764eb38f94e623c192e6aa91f6d9a4ac9` reproduced:
100,000 INFER remained in the original dripper after a simulated year of hourly keeper attempts.
Its maximum ordinary step was below the launch's fixed `minDrip = 1000e18`.

In `src/InferDripper.sol`, ordinary releases retain the existing seven-day decay and one-hour catch-up
cap. Once a full hour has elapsed, a step below `minDrip` becomes `min(balance, minDrip)`, as proposed
by the audit. This includes the final sub-minimum dust. A common readiness check keeps `canDrip`
consistent with `drip`, including an empty buffer. The timestamp advances on a successful release,
so the floor cannot be called repeatedly in one hour. The 1% keeper reward, empty-vault refusal,
constructor arguments and all constants are unchanged.

`test/StakingRegression.t.sol` verifies a 100,000-INFER buffer drains in 100 hourly steps (99,000 to
the vault, 1,000 to keepers), the exact hour boundary, final 1-wei dust, refusal of immediate repeats,
normal large-buffer releases, transition to the floor, the empty-vault guard and fuzzed final balances.
The existing exponential-decay test still passes for buffers whose ordinary steps exceed the floor.

### Mis-scaled future season start locking its pot — low

Finding `af98e48a8ef8006372a34346a964d7e72ac5b9ef8e270dd3e008d7deb8c3eaaa` reproduced:
`openSeason(1760000000000, 310000000e18, formula)` accepted a millisecond timestamp and reserved the
allocation for roughly 55,000 years.

In `src/SeasonVault.sol`, `MAX_NOTICE = 365 days` and `TooFar` reject starts beyond one year from
opening, using the audit's proposed bound. The 48-hour minimum, 13-week season length, non-overlap
check and deadlines are unchanged. Arbitrarily long pauses remain possible by waiting before opening
the next season. `test/Buckets.t.sol` verifies rejection without any reserved funds, acceptance at
exactly 365 days, rejection one second beyond it and a subsequent season after a five-year pause.

### Legacy redemption prerequisites — informational

Finding `df1a15ed0608093215d62e61e42c9bb47be60cb3665d7c39a2978ea3fff7fa19` reproduced on mainnet:
the existing no-NFT holder's MIYA redemption reverts until Milady #1 is transferred to the redeemer.
MXXN redemption burns exactly its input; clock upkeep requires a separate dust donation.

No production redemption code changed. `README.md` now contains the post-launch plan, including
the splitter call, operator-provided NFT before offering MIYA redemptions, MXXN clock catch-up by a
holder and donation during a permitted window, and subsequent permissionless clock upkeep.
The NFT is returned after the year to the specified `nftReturnTo`; no NFT or replacement recipient
was assumed to be available. Delaying these steps does not reset the construction-time redemption
deadline. No factory initialization call or constructor token/NFT transfer was added.

`test/LegacyRedeemer.t.sol` retains the successful mainnet NFT/window tests and adds explicit
assertions that `advanceClock` fails unfunded and that only the separately donated MXXN remains
after redemption. A local test verifies donation consumption and failure after exhaustion.

## Additional launch-required constructor correction

The vendored OpenZeppelin ERC-4626 constructor calls `SafeERC20.tryGetDecimals(asset_)`. A zero-call
expectation reproduced one external `decimals()` call in the original `StakedInfer` construction,
contrary to this launch's explicit restriction. The only permitted external constructor call is
InferDripper reading the earlier StakedInfer's `asset()`.

`src/base/ERC4626StaticAsset.sol` is a local copy of the already-vendored OpenZeppelin v5.7.0 base,
with its MIT license in `src/base/LICENSE`. Its only functional difference is receiving the asset
decimals as a static constructor word instead of probing external metadata. Imports and the abstract
contract name are adjusted for its location; all vault workflows, conversions, rounding and virtual
asset/share math are unchanged. `StakedInfer` supplies INFER's specified 18 decimals internally,
so its external constructor remains `[address infer]` and sINFER still has 24 decimals. The protected
`lib/` dependency was not edited.

`test/LaunchConstructors.t.sol` deploys the token and five applications in order with CREATE2 and
the exact arguments. Recorded constructor accesses contain only the permitted dripper `asset()`
read. Tests verify supply stays with the deploying factory analogue, allocations/rates/recipients
and share decimals. `test/StakingRegression.t.sol` differentially fuzzes deposits, donations,
previews, mint, withdraw and redeem against the vendored base after the one-block hold.

## Mainnet rehearsal and verification

`test/LaunchRehearsal.fork.t.sol` now uses the brief's actual treasury and governor, the previously
deployed splitter at `0xe95311cccf156cb18194d523cbe44cea33ad026e`, tick spacing 60 and Solidity artifact
name `InferToken`. Previously it used test recipients, a newly deployed splitter, spacing 200 and
the ticker as the token artifact name. It verifies the existing splitter's registry/treasury and
exercises the live factory deployment and all genesis payouts with the exact rates and economics.
These are test corrections to rehearse the specified launch, not changes to deployed dependencies.

Final checks with the project's unmodified configuration:

- `forge build`: passed (existing style/lint warnings remain).
- `forge test`: 76 passed, 0 failed; the two mainnet-only suites skip without a fork.
- `forge test --fork-url https://ethereum-rpc.publicnode.com -vv`: 80 passed, 0 failed, 0 skipped;
  mainnet block 26,166,930. Includes real MIYA/MXXN and the real factory and splitter.
- The factory launch call measured 8,891,274 gas in the fork harness, with 7,885,942 gas below its
  16,777,216 comparison cap. All three buckets received their full allocations; staking/dripper
  received no genesis allocation and the treasury received the remainder.
- Four delivered fuzz tests each ran the configured 512 cases. The supplied scratch proofs also
  passed after the fixes; the delivered regression tests retain their coverage independently.
- ABI/artifact inspection confirmed nonpayable, static constructors with at most 16 arguments,
  no unresolved libraries, no DELEGATECALL/CALLCODE/SELFDESTRUCT in any launch runtime, and every
  runtime below 24,576 bytes (largest: SeasonVault, 12,789 bytes).
- `git diff --check`: passed. Protected configuration/dependency paths and the INFER token are unchanged.

Verification consisted of source review, reproduction, Foundry unit/fuzz tests and mainnet fork
execution. Slither and Mythril were not run. Season roots still depend on the existing panel/governor
trust model for correct allocations; the new registration bound enforces the total but does not
calculate points or correct a bad leaf file. The NFT and dust operating steps remain necessary.

## Revision review

The accepted implementation was retained. Before changing production code, the four supplied proofs
were copied unmodified to `test/scratch/` and run with
`forge test --match-path 'test/scratch/Proof_*.t.sol' -vv`. The three previous proofs passed; both
tests in `Proof_e31963921ec5.t.sol` failed, showing approximately 2,946.43 INFER stranded after the
first drip. New delivered regressions reproduced the two SeasonVault issues and MXXN dust depletion.
The real MXXN fork test also reproduced depletion: an extra 999-step call after catching up burned
all 999 remaining dust units. No prior accepted fix was rewritten.

### Dust-backed staking vault — e31963921ec591f0321720d932e20c350cb2228c47986b85d9577f0b7c4d0918

`src/InferDripper.sol`: `drip` and `canDrip` now require at least `MIN_VAULT_SHARES = 1e9` real raw
shares. StakedInfer has `1e6` virtual shares, so their fraction of each new reward is at most
`1 / 1001`, below 0.1% apart from wei rounding. A nonzero balance alone was insufficient; direct
asset donations can inflate backing without reducing virtual shares' weight. The share bound is
independent of donations and is rechecked after withdrawals. Rejected calls preserve the buffer,
keeper balance and timestamp; deposits can restore readiness. Token, ERC-4626 math, `minDrip`,
release rates, keeper fee and schedules are unchanged. A small virtual-share fraction remains by
design; this fix bounds it rather than removing the vault's inflation defense.

`test/Revision.t.sol`: one-wei deposit, donation bypass attempt, exact share threshold, withdrawal
below it, resumed staking followed by full exit, and 512 fuzz cases bounding each drip's virtual
capture across floor and ordinary releases. Both supplied proof tests now pass.

### Root-deadline race — 4cecd0d95ee3db8f123e9376130a04db20f12131751340526303504df2723dd8

`src/SeasonVault.sol`: `_checkRootable` refuses a root at or after the existing
`endOf(s) + ROOT_DEADLINE`, whether attested or proposed. `proposeRoot` also requires its 48-hour
delay to finish strictly before that deadline. This makes root assignment and rootless expiry
mutually exclusive. A proposal not applied in time expires with the pot; a pending proposal cannot
extend or indefinitely block the existing expiry schedule. Equality belongs to expiry, so an ETA
exactly at the deadline is refused too. No constants, season dates, pots or vesting periods changed.

`test/Revision.t.sol`: the last-hour proposal is refused; ETA equality is refused; the last timely
proposal and attested root succeed; late `applyProposal` and `submitAttestedRoot` cannot race
`expire`. A refused signed submission does not consume its request ID. These tests failed on the
starting implementation where appropriate, and now pass.

### Registered claims after expiry — 8531094ce811e469d15171656a8f4056bc62920f660f96c5afc9e925a7a6556e

`src/SeasonVault.sol`: `_register` recognizes an existing entitlement before checking the registration
deadline. `claim` can therefore release the stored entitlement after the deadline or `expire`, just
like `release` and `distribute`. New accounts still need a valid proof before the deadline and remain
bounded by the root's unregistered total. Repeat calls cannot replace an entitlement or pay it twice.
`test/Revision.t.sol` reproduces both prior `PastDeadline` failures and tests full payment, repeat
calls, ignored replacement amounts, unchanged registered totals and refusal of new registrations.

### Clock upkeep donation depletion — cff67a8803e4e70969bc36984022b963f2108553b1ecc3ab894a750833db85ef

`src/LegacyRedeemer.sol`: for legacyB (the fixed MXXN slot), each iteration reads `moonConfig()` and
stops when `block.number <= end`. Only a genuinely stale window consumes a donated wei. `steps`
remains the caller's maximum work bound; calls remain permissionless, and constructors still make
no external calls. LegacyA's existing dust-burn behavior is unchanged. A per-call step cap alone
would not protect the donation against repeated calls, so the fix checks the actual clock instead.

`test/LegacyRedeemer.t.sol`: a clock-aware token reproduces needless burning, then verifies current
and future windows, repeated calls, the exact end block, multi-cycle catch-up, the caller's step
limit, later-window upkeep and unfunded stale-clock failure. The earlier donation test now uses that
clock-aware stand-in because the production code reads MXXN's clock. The mainnet test retains the
actual NFT, transfer-window, burn and donation checks and adds the oversized upkeep regression.

### Documented limits; no redesign

- `5a64b8041991b3055ffbc51be80a3d59f4ce5cd081c98d8581eb82bf0e05804c`: reproduced at the launch
  rates in `test_immediateCapIsPerWalletAtTheLaunchRate`. One 2M-MIYA redemption vests its excess;
  ten wallets redeeming 200k each receive the same combined amount immediately. `README.md` now
  explicitly states that the cap is per wallet, not per identity, and transferable tokens can be
  split among wallets. Redemption behavior remains the agreed rule; no global cap was invented.
- `6eee022f7ee474aba37c7c0e11fbddcfae25258c54010e1d7ef5754adf44eee3`: confirmed the governor's
  ability to end an unopened program and route 310M to treasury after 48 hours, and the absence of
  any automatic escape after 100 years without governor action. Both cases have delivered tests.
  `README.md` records allocation authority and indefinite lock risk if the governor key is lost.
- `476336530387afa5813e7adbe7cea0892e4840cf60513003ca572a2da9396a92`: confirmed the fixed signer
  in source and tested immediate, final roots through the existing virtual test-signer hook.
  `README.md` states that the one attester key is trusted for correctness and cannot be vetoed by
  the governor. No signature checks or administrative powers changed.
- `df1a15ed0608093215d62e61e42c9bb47be60cb3665d7c39a2978ea3fff7fa19`: the fork again reproduced
  MIYA's NFT prerequisite and MXXN's donation requirement. The accepted operational plan remains
  in `README.md`, with the new current-clock stopping behavior clarified.

### Prior findings and formatting

The original root-total, dust-grief and small-buffer findings (`aee37e82cc12`, `b45095aca81c`,
`75c201f59354`) no longer reproduce: their supplied proofs passed on this revision's starting tree.
The millisecond-start case (`af98e48a8ef8`) also reverted as intended in the existing regression.
Their accepted fixes and tests were retained.

`173c9143002d0cb525062ec245e5633df846fcba082823bef651aaf00c93ad76`: `forge fmt --check`
reproduced formatting differences in `LegacyRedeemer.sol` and `SeasonAttestation.sol`.
`forge fmt` was applied to delivered source/tests; SeasonAttestation's changes are formatting only.
`README.md` describes the revised operational boundaries. `.imd-responses.json` records a verdict
for every reported finding, including the earlier findings and documentation-only resolutions.

### Revision verification

- `forge build`: passed with the existing configuration; compiler/lint warnings remain.
- `forge test`: 93 passed, 0 failed, 2 fork-suite setup skips, after removing the scratch proof copies.
- `forge test --fork-url https://ethereum-rpc.publicnode.com -vv`: 97 passed, 0 failed, 0 skipped,
  mainnet block 26,167,129. The live factory rehearsal used 8,973,631 gas and the existing splitter
  paid every allocation in full. The real MIYA/MXXN prerequisite and upkeep tests passed.
- All five tests across the four unmodified supplied proof files passed before scratch cleanup.
- The five delivered fuzz tests each ran the configured 512 cases.
- `forge fmt --check` and `git diff --check`: passed. All 13 response IDs are present exactly once
  with valid verdicts in `.imd-responses.json`.
- Production edits are confined to InferDripper, SeasonVault and LegacyRedeemer, plus formatting
  in SeasonAttestation. The token, StakedInfer, FounderStream, constructor signatures, allocations,
  rates, recipients, build configuration and dependencies are unchanged from the accepted tree.

No packages were installed, no transactions were broadcast, and no manifest was written. Source
review and Foundry tests were used; Slither and Mythril were not run in this revision.
