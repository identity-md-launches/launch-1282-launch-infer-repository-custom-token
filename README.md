# infer-launch

Contracts for the INFER custom-token launch.

| contract | what it is |
|---|---|
| `InferToken` | the token: fixed supply of 1,000,000,000, minted once to the launch factory |
| `LegacyRedeemer` | burn MIYA or MXXN for INFER at fixed rates for one year; large redemptions vest |
| `SeasonVault` | the points allocation, paid in seasons the governor opens; roots attested by a swarm panel (`SeasonAttestation`) |
| `FounderStream` | the founder allocation, linear over 12 months with a 30-day cliff |
| `StakedInfer` | sINFER, an ERC-4626 vault over INFER |
| `InferDripper` | streams INFER bought with protocol revenue into sINFER |

The launch remainder goes to a `GenesisSplitter` (in `lib/genesis-splitter`), deployed before the launch, which
pays each contract above its `genesisAllocation()`.

```
forge build
forge test                                  # unit tests
forge test --fork-url <mainnet RPC>         # also: the launch through the live ProjectFactory, MIYA and MXXN
```

## Launch and operation

Ethereum mainnet, paired with IMD at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`.
The application deployment order is `LegacyRedeemer`, `SeasonVault`, `StakedInfer`, `FounderStream`,
`InferDripper`; the last constructor reads the earlier vault's `asset()`. All other constructors make
no external calls. The fixed constructor arguments are exercised in `test/LaunchConstructors.t.sol`
and the mainnet factory rehearsal in `test/LaunchRehearsal.fork.t.sol`.

The manifest step must copy these economics exactly:

```json
{"poolBps":2000,"initialMarketCapWei":"14444444444444444444444","remainderTo":"0xe95311cccf156cb18194d523cbe44cea33ad026e"}
```

The pool fee is `12500`, tick spacing `60`, and manifest initial price
`"79228162514264337593543950336"`; the factory derives the actual opening price from the market cap.
The token is `InferToken`, with no constructor arguments, 18 decimals and total supply
`1000000000000000000000000000`. `launch.json` is produced by the subsequent manifest step.

After launch:

1. Anyone calls `split(launchNumber)` on the existing GenesisSplitter at
   `0xe95311cccf156cb18194d523cbe44cea33ad026e`. It pays 140M INFER to LegacyRedeemer
   (100M for MIYA and 40M for MXXN), 310M to SeasonVault and 70M to FounderStream.
   The balance goes to treasury `0x6ac8ff96fb8dcf5d79a8ef1e59d9ac23f2bd27bc`
   (180M plus unused pool-seeding rounding). StakedInfer and InferDripper declare no allocation.
2. Before offering MIYA redemption, an operator must transfer an NFT from a MIYA-accepted collection
   checked before its reverting whitelist entry to the deployed LegacyRedeemer. The mainnet fork test
   proves this using Milady #1; the launch itself supplies no NFT. A holder without an accepted NFT
   cannot redeem until the redeemer holds one. Anyone can return that NFT after `closesAt` through
   `releaseNft`; the fixed return recipient is `0x5167d014a056e43883e1bbea5530c3c0dc993281`.
3. A MXXN holder must bring its moon clock current with 1-wei burns if needed, then donate upkeep dust
   to LegacyRedeemer during a permitted full-moon transfer window. Thereafter anyone can call
   `advanceClock(MXXN, steps)`, consuming 1 wei of the donated MXXN per step. Redemption burns exactly
   its input and does not replenish this dust. MXXN's own transfer windows continue to apply.
4. Governor `0xbefd108085613662356aa26a2466ad3426da9c32` opens seasons with 48 hours to 365 days of
   notice and a committed rules CID hash. Seasons still last 13 weeks and cannot overlap; arbitrary
   pauses are possible by waiting to open the next season. Publish the rules and leaf file when
   requesting a panel attestation, or use the governor's existing 48-hour fallback.
5. The treasury sends revenue-bought INFER to InferDripper. With shares outstanding, anyone calls
   `drip()`. Ordinary releases keep the seven-day decay and one-hour catch-up cap. A small buffer
   releases up to 1,000 INFER per full hour, including its final dust, rather than remaining stuck.

The redemption year and founder vesting clock both begin at construction. Funding and the NFT/dust
steps do not reset or extend them. These are post-launch asset transfers and permissionless operating
calls, not initialization calls by the factory. See [ADAPTATION.md](ADAPTATION.md) for findings and tests.
