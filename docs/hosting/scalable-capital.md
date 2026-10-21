# Scalable Capital on Docker / NAS

This self-hosted, alpha integration uses the [official Scalable CLI](https://github.com/ScalableCapital/scalable-cli),
not browser scraping. The application Dockerfile includes the official v1.1.0
Linux binary for amd64/arm64, verified against pinned SHA-256 checksums. No
additional public port, Docker socket mount, AI subscription or aggregator is needed.

## Connect

1. Deploy the new image and apply the new database migration through your normal,
   backed-up release process. Both **web and worker** need the same image and the
   same persistent `/rails/storage` mount. Do not start a new Compose project or
   replace existing volumes. Follow the [existing NAS deployment procedure](nas-github-actions.md).
2. On the Scalable **website**, enable **Profile → Security → Agentic Investing →
   Scalable CLI**. Select read-only permissions there if offered. Feature availability
   must be verified on your actual account.
3. In Wallet, choose **New account → Investments → Scalable Capital**. Create the
   connection and open its instructions. Creating it does not authenticate you or
   contact the broker.
4. On this NAS, in the existing `/srv/g96-data/compose/wallet` directory, run:

   ```sh
   sudo docker compose -f compose.yml -f .compose.github-image.yml exec --user 1000:1000 worker ruby bin/scalable-capital-session CONNECTION_UUID login
   ```

   Replace `CONNECTION_UUID` with the identifier displayed in the app. The script
   invokes the official `sc login --local-read-only`. Open the link yourself and
   complete browser authorization and trusted-device 2FA. Do not send passwords,
   verification codes, tokens or session files to an assistant.
5. Successful login queues the initial synchronization. The investment account is
   created only after a complete, valid snapshot is available. Subsequent imports
   participate in normal family sync; enable scheduled synchronization in hosting
   settings if not already enabled. You can also use **Synchronize** on the card.

## Imported data and limitations

- Current positions, including fractional quantities, identified by ISIN.
- EUR position valuations and cash, kept separate to avoid double-counting cash.
- All pages of the available **booked** Broker history: buys, sells, supported
  cash movements, dividends, interest, fees, taxes and security transfers.
- Trade amounts use the broker's **booked** total, which already accounts for
  charges, instead of quantity x price. Security transfers do not create cash flow.

The CLI is invoked once per read (overview, holdings, cash, one call per page of
transactions). A detail call is made only for trade, corporate-action and ELTIF
rows, because cash movements carry everything the ledger needs in the transaction
list itself. A long history therefore costs a manageable number of CLI calls
rather than one per operation.

Repeated imports use stable source/transaction identifiers; two equal deposits on
the same day are not merged. User-protected entries are respected. Empty complete
holdings snapshots close missing positions; malformed responses never clear them.

The initial sync uses the CLI's resolved/default Broker portfolio and pins its
identity for future syncs. Multiple portfolios without an unambiguous CLI context
require operator selection with the official CLI before the first sync. This
version does **not** discover and import every portfolio, Wealth mandate,
dedicated Overnight or Fixed-Term account.

Pending orders are excluded. Unknown booked event types, unsupported corporate
actions/ELTIF details, foreign-currency cash, and cancelled partially executed
orders fail the sync explicitly rather than being guessed or silently omitted.
History is limited to what Scalable exposes. Validate the first import against
broker statements before relying on reports: historical prices/cost bases before
the available history may be incomplete, and if the broker books a charge both
inside a trade and as a separate cash movement, the imported cash ledger can
differ slightly from the broker's cash figure. The account header always shows
the broker's reported total and cash. ISIN-only securities are created offline
to avoid speculative ticker matching; current valuations refresh on each sync.

## Session security and reauthorization

Each connection has a server-generated directory:
`storage/scalable_capital/FAMILY_UUID/CONNECTION_UUID`. OAuth sessions and DPoP
keys use the CLI file backend, without an interactive Linux keyring. Directories
are mode `0700`, configuration and lock files `0600`. Run as the app UID (1000 in
this Dockerfile). File locks serialize CLI login/refresh operations across containers.

These are **secrets on disk**, not database-encrypted credentials. Restrict NAS
storage/backup access and use encrypted storage/backups where possible. Never
check session files into Git. The app only issues literal read commands with
separate arguments, without a shell. `--local-read-only` is a local safeguard,
not a restriction on OAuth token permissions at Scalable.

If consent expires, run the same login command. To revoke a session before
removing the connection:

```sh
sudo docker compose -f compose.yml -f .compose.github-image.yml exec --user 1000:1000 worker ruby bin/scalable-capital-session CONNECTION_UUID logout
```

Also revoke access on Scalable's website. Removing the connection preserves the
imported Wallet accounts as manual accounts. Session directories are retained for
operator-managed secure cleanup; remove only the exact disconnected connection's
directory after revocation, never the shared storage volume.

Diagnostics use provider key `scalable_capital` in the existing debug settings.
Broker output, tokens and upstream error messages are not included in diagnostic
messages. `SCALABLE_CAPITAL_CLI_PATH` optionally selects an absolute executable
path for installations not using this Dockerfile.

## Verification

Database-free checks (no migration or broker access):

```sh
bundle exec ruby -Itest test/models/provider/scalable_capital_test.rb
bundle exec ruby -Itest test/models/provider/scalable_capital/normalizer_test.rb
```

After explicitly applying the migration in development/test, run model/controller
tests and the full pre-PR checklist. Successful unit tests do not mean that a real
Scalable account has been authorized or imported.
