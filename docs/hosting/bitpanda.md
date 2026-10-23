# Bitpanda (Crypto, alpha)

Bitpanda uses the read-only [Public API](https://docs.public.bitpanda.com/),
not the legacy API scheduled for retirement on 31 January 2027. No new
dependencies or Bitpanda trading permissions are required.

## Connect

1. Deploy the code and, as an explicit deployment step, run `bin/rails db:migrate`.
   This adds `bitpanda_items` and `bitpanda_accounts`; existing data is unchanged.
2. In Bitpanda Account Settings → API, create a Public API key with **Balances**
   and **Transaction** scopes only. Never grant trading/Earn write access.
3. As a household admin, open **Settings → Bank Sync → Crypto → Bitpanda**, then
   **Connect Bitpanda**. Paste the key into the password field in the application,
   not into an AI chat, command line, or issue.
4. Save. The background worker reads the entire available operation history and
   creates one Crypto exchange account. Its reporting currency is EUR; reports
   convert into the household currency using the application's normal FX handling.

Ensure Active Record encryption is configured in production. The API key and
stored snapshot are encrypted when the application's encryption configuration is
available, following existing provider conventions. Blank key updates retain the
existing key; saved keys are never echoed back into forms.

## Import behavior and limits

- The client only sends GET requests to `api.public.bitpanda.com`. Assets and
  operations are cursor-paginated until `has_next_page` is false. Missing/repeated
  cursors, conflicting duplicates, invalid decimals and incomplete snapshots fail
  the synchronization rather than silently accepting a truncated history.
- Holdings and cash come from `/v1/portfolio`, explicitly requesting EUR
  equivalents. All asset types returned by this endpoint are retained, not only
  crypto. Non-crypto instruments use provider-specific identifiers to avoid ticker
  collisions with cryptocurrencies, stocks or metals from other providers.
  Fiat wallets may omit `currency_balance`: EUR cash then uses the native balance,
  while foreign cash requires a valid exact-date FX rate into EUR. Missing asset
  valuations still fail the import rather than treating asset units as euros.
- One-asset/one-fiat purchases and sales produce a single Trade, including its
  cash effect. The fiat counterpart is retained in the Trade's provider metadata,
  not imported again as a second cash movement. Standalone fiat movements are
  Transactions. API transaction/operation identifiers make repeated imports
  idempotent, and user-edited entries remain protected.
- Asset transfers create cash-neutral quantity movements labelled **Transfer**.
  The movement itself keeps an unknown price and zero cash effect. When an
  inbound crypto transfer has no execution price, the importer records the
  exact-date EUR market quote from the free public Binance feed **for cost-basis
  purposes only**, clearly labelled as estimated in the portfolio and holding
  drawer; a manual cost basis overrides it. If no exact-date quote is available
  the basis stays unknown and the sync records a warning. `reclaim`/`refund`
  corrections are never valued this way.
- `reclaim` and `refund` balance corrections are retained as non-trading movements
  with their original quantities, directions and compensation references. They
  reuse the Transfer mechanics (zero cash effect for assets, unknown basis), but
  are named explicitly as corrections requiring review, not buys/sells or income.
  The connection shows a warning and support diagnostics record the need for
  review. This is not an automatic tax classification: verify these corrections
  against Bitpanda's statement before using gain/loss reports.
- Other asset movements without an execution quote (including rewards and unpaired crypto swaps) require an exact-date
  security price available through the application's market-data support. New
  crypto assets can resolve to an exact-base match from enabled price providers;
  no fuzzy ticker match is accepted. Assets with no match remain offline.
  Enable an available crypto price provider under **Settings → Hosting → Market
  data** before syncing historical rewards. **Binance Public** is supported,
  requires no API key and supplies historical daily market quotes. Selecting
  Twelve Data without configuring its API key does not provide usable prices.
  The Public API's `cryptocoin` asset type is recognized as crypto; equities with
  the same symbol are kept separate.
  Without a price, the entire financial import rolls back and reports which
  symbol/date needs attention. Current spot prices are never substituted for
   historical prices. Swaps with separate trade IDs pair each asset leg with its
   own fiat leg. Their actual cash effects are retained, without duplicate fiat
   entries. `trade.rate_with_fee` supplies the execution unit price when present;
   the fiat amount remains authoritative for the movement's EUR value. Unpaired
   swaps use the available historical market quote, labelled as an estimate.
- Native fee amounts, order/trade identifiers, compensation fields and all legs
  are retained in provider metadata. Fees are not independently charged again
  on top of the API's ledger cash movements. Do not treat this alpha integration
  as a complete tax/cost-basis statement; verify fees and execution valuations
  against Bitpanda's export before relying on those reports.
- Unknown operation types stop the import. Staking balances and historical scope
  are limited to what the Public API actually returns; the application cannot
  promise coverage of products/history omitted by Bitpanda.
- Disconnecting removes the provider connection asynchronously while preserving
  imported accounts, entries and holdings as manual records. Revoking the API key
  itself must be done in Bitpanda.

Failed imports are visible in synchronization status and support diagnostics
(`provider_key: bitpanda`), scoped to the household. API response bodies and keys
are not included in HTTP errors.

## Small token prices (PEPE and similar assets)

Migration `20261023130000` increases quote, holding and trade unit prices to
`decimal(34,18)`. Previously the quote/holding columns had only four decimal
places, which could turn a valid token quote into zero. Currency totals retain
their existing precision. Increasing precision preserves existing values but
cannot recover decimals already lost; zero crypto quote-cache entries are
re-fetched from their configured provider, using the exact date and currency.
Positive cached quotes and non-crypto zero quotes are not overwritten.

Apply the migration explicitly during deployment. It changes three columns and
can take table locks; plan accordingly for large installations. Downgrading this
migration is intentionally blocked to avoid truncating stored financial data.

## Crypto movement ledger and manual portfolios

Migration `20261023140000` adds nullable `entries.occurred_at` and an account/time
index. Daily dates and existing reports remain unchanged. Resynchronization
backfills timestamps from Bitpanda. Historical records without a timestamp show
their date and an explicit “time not recorded” label.

Crypto uses the same daily activity groups, search, selection controls and
click-to-open drawer as the other accounts. Each list row shows description,
timestamp, action, signed native quantity and signed EUR value. The standard
drawer's Overview and Details sections contain the unit price, fees, native
balance after the movement and price source, alongside existing notes, settings
and transaction attachments. A zero accounting cash effect is not displayed as
a zero asset value. Crypto financial metadata is shown read-only rather than
editing the generic accounting amount independently of its native movement.
Original descriptions and native balances come from the stored API snapshot;
missing descriptions fall back to action/asset, not invented exchange wording.
Missing valuations remain unavailable. Market quotes and dated FX conversions
are identified separately from Bitpanda execution values. Trading fees are shown
in the matched fiat quote's units; movement fees retain their native units. Fees
already present in Bitpanda cash amounts are not charged twice.

Old duplicate fiat counterparts are excluded, not deleted. A user-edited
counterpart blocks regrouping until reconciled; existing excluded entries remain
excluded, including any deliberately excluded correction/reward movements.

Manual Crypto accounts offer **Add crypto movement**, supporting buy, sell,
deposit, withdrawal and two-leg swaps. Enter positive quantities and choose the
time zone explicitly. Entered unit prices or EUR values take priority. Otherwise
Binance Public can supply the opening quote of the exact selected UTC minute in
an EUR pair, without an API key. This public endpoint is not CoinMarketCap and is
not an open-source pricing guarantee: pair listings, regional access and history
can limit availability. There is no current-price or USD-pair fallback; enter
the execution price manually when unavailable. Accepted suggestions retain their
market source and quote timestamp.

Select whether payments/proceeds and EUR fees use the portfolio's EUR balance or
external funding. Swaps do not invent EUR proceeds. Running balances include
earlier pages and excluded movements are ignored. A nonzero opening valuation
does not specify native quantities: supply a known native balance after a
movement to anchor that currency. The summary continues to show current total
portfolio value in EUR, not a reconstructed historical EUR total per row.

## Validation

Synthetic fixtures follow the published Public API schemas and contain no real
credentials or account data. They do not replace a live read-only acceptance test
against your own Bitpanda portfolio and CSV export.

```sh
bin/rails test test/models/provider/bitpanda_test.rb test/models/provider/bitpanda/normalizer_test.rb test/models/bitpanda_item/syncer_test.rb test/controllers/bitpanda_items_controller_test.rb
```
