# Chatwait — UPI Payouts: Implementation Spec

> **Status:** proposed, ready for implementation.
> **Target codebase:** the private source-of-truth repo — the chatwait web app (`chatwait.com`) and
> the `api.chatwait.com` backend (`/functions/v1/*` edge functions). **Not** this public extension
> mirror, which ships no payout code (see §3).
> **Date:** 2026-10-21.

## 1. Decisions locked

| Decision | Choice | Rationale |
|---|---|---|
| Provider | **Cashfree Payouts** | Supports UPI VPA beneficiaries and — critically — the Validate Payout → Process Validated Payout flow that gates a payout on a verified VPA. |
| Currency | **FX snapshot at request time** | Earnings accrue in USD; UPI pays INR. The rate is locked onto the payout row when the user requests the payout, so the agreed INR amount can never drift afterwards. |
| Minimum payout | **₹100** | Per-impression payouts are ~$0.000005, so balances accumulate slowly. A low floor keeps UPI actually usable; a high one strands most users below the threshold forever. |
| VPA verification | **Cashfree Validate Payout** | A VPA is monetizable PII. The provider resolving the VPA and returning the registered beneficiary name is the only ownership check that cannot be faked by the user. |
| API generation | **Payouts V2** | The V1 direct-transfer endpoint is documented as retiring; beneficiary ID formats differ between V1 and V2, so new beneficiaries must be V2. |

## 2. Scope

**In scope**

- A user saves one or more UPI destinations (VPA) on the dashboard.
- Each saved VPA is verified and shows the beneficiary name Cashfree resolved for it.
- A user requests a payout to a verified VPA; the backend converts USD→INR at a snapshotted
  rate and pays via Cashfree.
- Payout state is tracked in a ledger and driven by Cashfree webhooks.
- Payout history is visible on the dashboard.

**Out of scope**

- Bank account / IMPS / NEFT / RTGS payouts, cards, wallets, Cashgram. (Cashfree supports all of
  these; the schema's `method` check is deliberately constrained to `upi` so the others can be
  added without a rewrite.)
- Cashfree Secure ID KYC (Aadhaar, PAN, biometrics, Video KYC). Worth adding later, but it is a
  separate product decision and is not required to pay out to a VPA.
- International payouts. UPI is India-only.
- Caching, retry and rate-limit tuning of the extension's event pipeline.

## 3. Why this is not in the browser extension

The extension has no payout surface today, and adding one would be wrong, not merely redundant:

1. **The extension holds no account credential.** Its entire API surface is five endpoints
   (`ads-bundle`, `events`, `device-status`, `user-earnings`, `uninstall`), all keyed off
   `device_id` + `device_token`. There is no user session, no JWT, no `user_id` — see
   `lib/api.ts:93-102` and `entrypoints/background.ts`.
2. **`device_id` is a bearer credential that leaks by design.** The extension's own comment says
   so: *"a bare device_id is a bearer credential that leaks by design (Awin clickref, the
   `?device=` click-URL param)"* (`lib/api.ts:94-96`). A bearer credential that can move money
   is a fraud magnet; whoever holds a leaked `device_id` could trigger payouts.
3. **A VPA must never enter extension storage.** The extension deliberately keeps ad tokens and
   device tokens in `browser.storage.local` and out of page `localStorage` (`lib/storage.ts:226-230`).
   A VPA is stronger PII than either.
4. **It would not fit the store policies.** Adding a VPA to the extension changes what
   `PRIVACY.md` describes and what the AMO `browser_specific_settings.gecko.data_collection_permissions`
   block in `wxt.config.ts:158-166` declares.

**Consequence: zero extension changes.** The dashboard already exists and is already linked from
the popup — `entrypoints/popup/main.ts:121-123` opens `https://chatwait.com/dashboard`. Payout
settings live there. The only optional extension touch is a one-line label change if the popup
should mention payouts; nothing functional.

## 4. Architecture

```
chatwait.com/dashboard/payouts        (web app, user session)
        |  POST /functions/v1/payout-methods
        |  POST /functions/v1/payouts
        v
api.chatwait.com edge functions        (our backend: auth, money, ledger)
        |  POST https://api.cashfree.com/payout/validatePayout
        |  POST https://api.cashfree.com/payout/transfers
        v
Cashfree Payouts  --->  UPI rail  --->  user's bank account
        |
        |  POST /functions/v1/webhooks/cashfree   (signature-verified)
        v
api.chatwait.com edge functions        (state transitions, ledger updates)
```

Auth model: the web app calls our edge functions with the user's real session (Supabase-style
JWT). **This is a different credential from the extension's device token, and that difference is
the whole reason payouts live here.** The backend must derive `user_id` from the session, never
from a request body.

## 5. Verified provider facts

Everything in this section was read from Cashfree's live documentation on 2026-10-21, not from
memory. The two that most often break implementations are called out.

### 5.1 Once a request is accepted, the verdict is in the body — not the status code

> *"Always returns HTTP 200 when the payout request is accepted. Use `status` and `status_code`
> for the lifecycle."* — Process Validated Payout

> *"Always returns HTTP 200 when the request is accepted. Use `account_status`, `transfer_token`,
> and related fields to judge VPA..."* — Validate Payout

A `res.ok` check is therefore **not sufficient** for an accepted request. Every call must read
`status` / `status_code` / `account_status` / `sub_code` out of the body.

To be precise about the boundary: *transport and authentication* failures are ordinary HTTP
errors (400 for a missing header, 401 for bad credentials — see §8), and *operation* failures —
a VPA that does not exist, a declined transfer — come back as HTTP 200 with the verdict in the
body. It is the second kind that a `res.ok` check silently swallows. Failure sub-codes observed in the V2 response
code table include `INVALID_BENE_VPA`, `INSUFFICIENT_BALANCE`, `BENE_BANK_DECLINED`,
`NPCI_UNAVAILABLE`, `DEST_LIMIT_BREACHED`, `SOURCE_BANK_DECLINED`, `REINITIALIZE_TRANSFER_LATER`,
`RETURNED_FROM_BENEFICIARY`, `ACCOUNT_BLOCKED`, `AUTHENTICATION_FAILURE`.

### 5.2 UPI cannot be paid from the Payout Wallet

> *"UPI is not available under the Payout Wallet (CF_WALLET) funding source. UPI payout transfers
> via the Payout Wallet have been disabled due to partner bank unavailability. This is a
> platform-level restriction and cannot be enabled for specific funding sources at this time. If
> you attempt a UPI payout using the Payout Wallet, you will receive the error 'The transfer has
> been rejected because the payment instrument does not support this mode of transfer'."*

**Action:** a connected bank account must be registered as a fund source, and its
`fundsource_id` must be passed explicitly on every UPI transfer. If the deployment only has the
default Cashfree Wallet, UPI payouts will fail 100% of the time with a message that does not
mention UPI. Verify the fund source before enabling the feature.

### 5.3 UPI transfer limits

> *"The transaction limit per UPI payouts is Rs. 1 lakh. Although the transaction limit is
> Rs. 1 Lakh, the upper limit might vary from bank to bank. This limit ranges from Rs. 10,000 to
> Rs. 1 lakh."*

A payout larger than ₹1,00,000 must be split across multiple transfers. See §10.3.

### 5.4 Beneficiary requirements

A UPI beneficiary is registered with `POST https://api.cashfree.com/payout/beneficiary` and
needs `beneficiary_id`, `name`, `email`, `phone` and the VPA. *"If the provided
VPA is incorrect, then the payout fails on initiation."* A beneficiary can be registered once
via `POST /beneficiary` (V2) and reused, or let the Process Validated Payout flow create it
implicitly — it returns a `beneficiary_id` in `beneficiary_details`.

### 5.5 Webhook signature

- Headers: `x-webhook-signature`, `x-webhook-timestamp`.
- Signed string: `timestamp + rawBody`.
- Algorithm: HMAC-SHA256, base64-encoded, keyed with the **oldest active client secret**
  (using a different key causes a signature mismatch).
- The endpoint must answer HTTP 200. *"Any response code outside the 200 range, including 3xx
  codes, indicates that you didn't receive the webhook."* Cashfree retries with a decreasing
  rate and **disables the webhook after roughly five consecutive failures** — so a handler that
  throws on an unexpected event silently kills all payout notifications.
- Events: `TRANSFER_SUCCESS`, `TRANSFER_FAILED`, `TRANSFER_REVERSED`, `TRANSFER_ACKNOWLEDGED`,
  `TRANSFER_REJECTED`, `TRANSFER_APPROVED`, `BENEFICIARY_INCIDENT`, `CREDIT_CONFIRMATION`,
  `LOW_BALANCE_ALERT`.
- `TRANSFER_SUCCESS` carries an `acknowledged` flag: `1` means the transfer is confirmed paid;
  `0` means wait for `TRANSFER_ACKNOWLEDGED` or poll Get Transfer Status.

### 5.6 Lifecycle

`Pending → Success | Failed`, `Success → Reversed`; `Rejected` is final. The async path adds
`Received` before the rest. A failed transfer whose amount was already debited is reversed back
to the Cashfree account by the remitter bank within 24 hours. `Reversed` is terminal and
Cashfree credits the original amount back to the Payouts account.

## 6. Data model

Full DDL: [`migrations/20261021_001_upi_payout.sql`](./migrations/20261021_001_upi_payout.sql).
Three tables and one view.

**`fx_rates`** — daily USD→INR snapshots, keyed `(base_currency, quote_currency, as_of)`, with
`rate > 0` enforced. A payout reads the latest `as_of <= today` and copies the rate onto its own
row. Populate this daily from a scheduled job **before** enabling payouts: a missing rate must
fail the payout request, never silently fall back to 1.0.

**`payout_accounts`** — a user's saved UPI destination and its verification state.

| Column | Purpose |
|---|---|
| `user_id` | Owning account. `unique (user_id, upi_vpa)` — re-adding the same VPA re-verifies it rather than creating a second row that could be paid independently. |
| `upi_vpa` | The full VPA (`name@bank`). PII: never log in full, never put in a URL, never write to page storage. |
| `beneficiary_name` | The name Cashfree resolved for the VPA — shown back to the user to confirm. |
| `status` | `pending_verification` → `verified` → `rejected`. |

**`payouts`** — the money ledger.

| Column | Purpose |
|---|---|
| `amount_usd` | What we reserved from the user's settled earnings. |
| `fx_rate` | The snapshot actually used, so a later rate move never changes an agreed payout. |
| `amount_inr` | What the user receives. `check (amount_inr >= 100)` enforces the ₹100 floor at the database level. |
| `status` | `requested` → `validated` → `processing` → `paid` \| `failed` \| `rejected` \| `reversed`. |
| `transfer_id` | Our idempotency key, sent to Cashfree verbatim as their `transfer_id`. `unique` — one Cashfree transfer per payout row, ever. |
| `cf_transfer_id` | Cashfree's identifier, surfaced on their webhooks. |

**`payout_available_balances`** (view) — `settled earnings − sum(amount_usd) reserved by
payouts still in flight`. A payout row leaves the reserved set the moment it reaches a terminal
state, so `failed`, `rejected` and `reversed` all release the money back to the user for a retry.

> **Integration point:** the view's `settled` CTE is a placeholder returning no rows. It must be
> replaced with the real settled-earnings query (whatever backs
> `GET /functions/v1/user-earnings`, which currently returns a `total_usd` figure). Until it is
> wired the view yields `available_usd <= 0` for everyone, so **payouts fail closed** — you cannot
> pay out money the system cannot see. This is deliberate.

## 7. Our API contracts

All endpoints live under `https://api.chatwait.com/functions/v1/`, matching the existing
`/functions/v1/*` style, and all require the user's real session. `user_id` is derived from the
session, never accepted from the request body.

### 7.1 `POST /payout-methods` — save and verify a VPA

**Request**

```json
{ "upi_vpa": "name@bank", "beneficiary_name": "Name As On Bank Record" }
```

**Response `201`**

```json
{
  "payout_account_id": "uuid",
  "status": "verified",
  "account_status": "VALID",
  "upi_vpa": "name@bank",
  "beneficiary_name": "NAME AS PER UPI RECORDS"
}
```

**Errors** — `422` malformed VPA or `account_status != VALID`; `429` too many attempts;
`409` that VPA is already saved for this user.

**Backend behaviour**

1. Format-check the VPA (`/^[A-Za-z0-9._-]{2,64}@[A-Za-z0-9]{2,64}$/`). Reject early — a
   malformed VPA costs a provider call.
2. Rate limit: max 5 validation attempts per user per hour; max 3 unverified accounts per user.
3. Call Cashfree `POST /payout/validatePayout` (see §8.1).
4. If `account_status != 'VALID'` or `transfer_token` is empty → return `422` and persist
   nothing. Note the response is still HTTP 200 from Cashfree, so this check is mandatory.
5. Upsert the `payout_accounts` row, storing the resolved `beneficiary_name`.
6. If `beneficiary_name` is present, **the user must confirm it matches their own VPA** before
   the account is marked `verified`. The provider's name resolution is the ownership signal;
   the user's confirmation is what binds it. A mismatch (or an empty name) leaves the account
   `pending_verification` and it cannot receive a payout.

### 7.2 `GET /payout-methods` — list saved destinations

Returns the user's accounts with `status`, `beneficiary_name` and `verified_at`. Never returns
the full VPA to a logged-out context, and the UI should mask it (`na****@okaxis`) outside the
payment form.

### 7.3 `POST /payouts` — request a payout

**Request**

```json
{ "payout_account_id": "uuid" }
```

The amount is **not** accepted from the client. The backend computes it from the available
balance (or withdraws the full eligible balance). A client-supplied amount is a classic way to
drain a balance into an account the attacker controls.

**Response `201`**

```json
{
  "payout_id": "uuid",
  "status": "processing",
  "amount_usd": "1.23",
  "fx_rate": "83.25",
  "amount_inr": "102.50",
  "transfer_id": "pw_20261021_000123"
}
```

**Errors** — `422` no verified account, below the ₹100 floor, or amount exceeds the available
balance; `409` a payout for this account is already in flight; `429` rate limited;
`502` provider unreachable (the reservation is released, the user can retry).

**Backend behaviour**

1. Load the account; require `status = 'verified'` and that it belongs to the caller.
2. Compute `available_usd` from the view. Require `available_usd > 0`.
3. Read today's `fx_rates` row. If missing → `422`, no fallback rate.
4. `amount_inr = round(available_usd * fx_rate, 2)`. If `amount_inr < 100` → `422` with the
   shortfall, so the UI can say "you need ₹12.40 more".
5. Cap `amount_inr` at ₹1,00,000 per transfer (§5.3). If the balance exceeds that, create
   multiple payout rows (§10.3).
6. Insert the `payouts` row with `status = 'requested'` and a fresh `transfer_id`. The unique
   index on `transfer_id` is the first line of idempotency defence.
7. Call Cashfree `POST /payout/transfers` (§8.2) using **the same `transfer_id`**.
8. On `status = 'SUCCESS'` → `paid`. On `status = 'RECEIVED'` → `processing` (the webhook
   finishes the job). On a failure sub-code → `failed` with the sub-code recorded, reservation
   released, and the user told in plain language.

### 7.4 `GET /payouts` — history

The user's payouts, newest first, with amount, FX rate, status and the Cashfree reference.

### 7.5 `POST /webhooks/cashfree` — provider callbacks

Public, unauthenticated, but **signature-verified**. See §9.

## 8. Cashfree integration

**Base address** (the Payout v2 APIs): production `https://api.cashfree.com/payout`, test
`https://sandbox.cashfree.com/payout`. The three endpoints this spec uses are therefore:

| Operation | URL |
|---|---|
| Validate Payout | `POST https://api.cashfree.com/payout/validatePayout` |
| Process Validated Payout | `POST https://api.cashfree.com/payout/transfers` |
| Create Beneficiary | `POST https://api.cashfree.com/payout/beneficiary` |

**Auth — the V2 API does not use `Authorization: Bearer`.** The credentials go in two headers:

```
x-client-id:     <client id>
x-client-secret: <client secret>
```

Observed behaviour: no `x-client-id` → HTTP 400
`{"type":"validation_error","code":"x-client-id_missing"}`; an id but no secret → HTTP 400
`x-client-secret_missing`; both present but wrong → HTTP 401
`{"type":"authentication_error","code":"authentication_failed","message":"Invalid clientId and
clientSecret combination"}`. Sending only an `Authorization: Bearer` header does **not**
authenticate a V2 call — it is ignored and the request still fails with `x-client-id_missing`.
The V1 API *does* use a bearer token; the two generations are not interchangeable, and the
OpenAPI snippets scattered through Cashfree's per-endpoint pages still show the V1 hosts.

Sandbox credentials are listed in Cashfree's *"Data to Test Integration"* page and must be used
for all of the test plan in §13.

Enable 2FA with IP whitelisting and public keys before going live — the payout API can move real
money, and an un-whitelisted credential is a payout-theft vector.

### 8.1 Validate Payout — `POST /payout/validatePayout`

Resolves a VPA on the UPI network and issues a **single-use transfer token valid for one hour**.

**Request body**

```json
{ "transfer_id": "pw_20261021_000123", "vpa": "name@bank" }
```

Pass exactly one of `vpa` or `phone` — never both.

**Response (HTTP 200 in every accepted case)**

```json
{
  "transfer_token": "9d37bc17-db08-476b-8206-f0f8ec9661ad",
  "vpa": "success@upi",
  "account_status": "VALID",
  "beneficiary_name": "NAME AS PER UPI RECORDS"
}
```

**The invalid case also returns HTTP 200**, with an empty token:

```json
{ "transfer_token": "", "vpa": "invalid@upi", "account_status": "INVALID" }
```

So the check is `account_status === 'VALID' && transfer_token !== ''` — never `res.ok`.

Advanced details (IFSC/branch) are only included if enabled for the account via the Cashfree
support form; treat them as optional.

### 8.2 Process Validated Payout — `POST /payout/transfers`

Initiates the UPI payout using the token from §8.1.

**Request body**

```json
{
  "transfer_id": "pw_20261021_000123",
  "transfer_token": "9d37bc17-db08-476b-8206-f0f8ec9661ad",
  "transfer_mode": "upi",
  "transfer_amount": "102.50",
  "fundsource_id": "YESB_CONNECTED"
}
```

- `transfer_amount` is a **string** in the schema (example `"1"`), in INR major units.
- `transfer_mode` must be `upi` when a transfer token is used — no other mode is accepted.
- `transfer_id` **must** be the same value used in the Validate Payout call.
- `fundsource_id` is optional in the schema but **mandatory in practice** for UPI: without it
  Cashfree falls back to the Payout Wallet and rejects the transfer (§5.2).
- `transfer_token` is consumed on use and expires after one hour.

**Response (HTTP 200 in every accepted case)**

```json
{
  "transfer_id": "pw_20261021_000123",
  "cf_transfer_id": "659928176",
  "status": "SUCCESS",
  "status_code": "COMPLETED",
  "status_description": "Transfer processed successfully",
  "beneficiary_details": {
    "beneficiary_id": "B_testTransferId3_69SIX9",
    "beneficiary_instrument_details": { "vpa": "name@bank" }
  },
  "transfer_amount": 102.50,
  "transfer_service_charge": 0,
  "transfer_service_tax": 0,
  "transfer_mode": "upi",
  "transfer_utr": "1732088013492889"
}
```

`status` was `RECEIVED` / `status_code` `RECEIVED` on an async acceptance. Branch on
`status`/`status_code` in the body, and persist `cf_transfer_id` so the webhook can be matched
back to the row.

### 8.3 The token has to be minted per payout, not per saved VPA

The token is single-use and expires in one hour. It therefore cannot be cached against a saved
`payout_accounts` row. The correct sequence for every payout request is:

```
POST /payout/validatePayout   (fresh, per payout, same transfer_id)
        -> transfer_token
POST /payout/transfers         (consumes the token)
```

A Validate Payout performed when the user *saves* their VPA is still worth doing — it confirms
the VPA exists and yields the beneficiary name for the confirmation step (§7.1 step 6) — but its
token must be discarded, not stored.

## 9. Webhook handling

`POST /webhooks/cashfree` must:

1. Read the **raw** request body. The signature is computed over the exact bytes received;
   re-serialising a parsed JSON object will change the bytes and break verification.
2. Read `x-webhook-signature` and `x-webhook-timestamp`.
3. Compute `base64(HMAC-SHA256(timestamp + rawBody, oldest_active_client_secret))` and compare
   with a constant-time comparison. A mismatch → `401`, and **do not** process the event.
4. Look up the payout by `transfer_id` (Cashfree echoes our own id back). Unknown id → `200`
   with a log line, not an error; an unrecognised event must never 5xx (§5.5).
5. Apply the state transition (§10.1), then return `200`.

Events to handle:

| Event | Effect on the payout row |
|---|---|
| `TRANSFER_SUCCESS` with `acknowledged = 1` | `status = 'paid'`, `settled_at = now()`. |
| `TRANSFER_SUCCESS` with `acknowledged = 0` | Leave as `processing`; wait for `TRANSFER_ACKNOWLEDGED` or poll Get Transfer Status. |
| `TRANSFER_ACKNOWLEDGED` | `status = 'paid'`, `settled_at = now()`. |
| `TRANSFER_FAILED` | `status = 'failed'`, record the reason, release the reservation. |
| `TRANSFER_REVERSED` | `status = 'reversed'`, release the reservation (Cashfree credits the amount back). |
| `TRANSFER_REJECTED` | `status = 'rejected'`, release the reservation. |
| `TRANSFER_APPROVED` | No ledger change; informational. |
| `BENEFICIARY_INCIDENT` | Mark the account for review; do not auto-fail unrelated payouts. |
| `LOW_BALANCE_ALERT` | Operational alert — top up the fund source. |

**Idempotency of the handler:** the same event can arrive more than once. Make every transition
conditional, e.g. `update payouts set status = 'paid' where transfer_id = $1 and status in
('requested','validated','processing')`, and check the affected-row count. A terminal state must
never be overwritten.

**Delivery failures:** any non-2xx response makes Cashfree retry with a decreasing rate and
disable the webhook after roughly five consecutive failures. Catch every error inside the
handler, log it, and still return `200` once the event has been durably recorded. If the
handler must fail, fail in a way that does not lose the event — persist it to a queue first.

## 10. State machine and money correctness

### 10.1 Payout states

```
                    +-------------------+
                    |    requested      |   row inserted, money reserved
                    +---------+---------+
                              |
              validate ok ----+---- validate failed
                              |         |
                    +---------v--+   +--v-----------+
                    | validated  |   |  rejected   |  terminal
                    +---------+--+   +-------------+
                              |
                 transfer ----+---- provider error
                              |         |
                    +---------v--+   +--v-----------+
                    | processing |   |   failed    |  terminal, money released
                    +---------+--+   +-------------+
                              |
        +---------------------+---------------------+
        |                     |                     |
   +----v-----+        +------v------+       +-----v-----+
   |   paid   |        |  reversed   |       | (sweeper)  |
   +----------+        +-------------+       +------------+
     terminal            terminal              terminal
```

Terminal states are `paid`, `failed`, `rejected`, `reversed`. Only a terminal state releases the
money reservation. A `paid` payout is final except for `paid → reversed`, which Cashfree
documents as a real transition (the beneficiary's bank can reverse it) and which must release the
reservation again.

### 10.2 Reservations — the money must never be spent twice

`available_usd` is derived, not stored:

```
available_usd = settled_earnings_usd
              - sum(amount_usd of payouts where status in ('requested','validated','processing'))
```

Consequences that the implementation must respect:

- The reservation is created by **inserting the payout row**, not by a separate balance
  mutation. There is no window in which money is neither reserved nor spent.
- A failed provider call must **delete or terminalise** the row in the same transaction that
  noticed the failure. If the row is left in `requested` after the transfer was never attempted,
  the user's money is stuck behind a reservation that no webhook will ever clear.
- A sweeper job must find rows that have been non-terminal for more than a few minutes, call
  Get Transfer Status, and reconcile them. Webhooks can be lost; the ledger cannot depend on
  them alone.

### 10.3 Amounts above the UPI cap

UPI is capped at ₹1,00,000 per transfer (§5.3), and the real cap can be lower for some banks
(documented range ₹10,000–₹1,00,000). If the user's balance converts to more than the cap:

- Split the balance into several payout rows, each with its own `transfer_id`, each under the
  cap. The first row is created immediately; the rest are created only as earlier ones reach a
  terminal state, so a failure on row 1 does not leave rows 2..n reserved.
- Cap conservatively (₹1,00,000 is the documented ceiling, not a guarantee) and re-check the
  per-transfer limit at the provider.

### 10.4 FX

- One row per day in `fx_rates`, written by a scheduled job.
- A payout copies the rate onto its own row at request time. Later rate changes never affect
  an already-agreed payout.
- If today's rate is missing, the payout fails with a clear error. Never default to 1.0.
- The rate is shown to the user *before* they confirm, and the same rate is what lands on the
  ledger row.
- The rate source is an open question — see §15.

## 11. Security

| Concern | Control |
|---|---|
| **Money moved by the wrong person** | The VPA is resolved by the provider and the resolved beneficiary name must be confirmed by the user before the account becomes `verified`. A payout can only target a `verified` account owned by the caller. |
| **Unverified VPAs used to launder money** | No payout to an unverified account. Max 3 pending accounts per user, max 5 validation attempts per hour. |
| **Client-supplied amounts** | The amount is computed server-side from the available balance. The request body carries only `payout_account_id`. |
| **Client-supplied identity** | `user_id` comes from the session, never the body. Every query is scoped by it. |
| **Double-spend** | Reservations (§10.2) + the unique `transfer_id` index + Cashfree's own 409 on a repeated transfer id. |
| **Webhook forgery** | HMAC-SHA256 over `timestamp + rawBody`, constant-time compare, using the oldest active client secret. Mismatch → `401`, no processing. |
| **Replay of a captured webhook** | Include a timestamp freshness check (reject events older than a few minutes) in addition to the signature. |
| **Credential theft** | Enable 2FA + IP whitelisting + public keys on the Cashfree account. The payout API key must never ship to the browser, the extension, or a log. |
| **VPA leakage** | Never log a full VPA — log `na****@okaxis`. Never place one in a URL, a referrer, an error message, or analytics. Mask it in every UI except the active payment form. |
| **Mass payout abuse** | Per-user daily/monthly payout caps and per-user request rate limits, on top of the ₹100 floor. |
| **Endpoint enumeration** | `/payout-methods` and `/payouts` must scope every read and write by the session's `user_id`; a mismatched `payout_account_id` returns `404`, not `403`, so the endpoint does not confirm that the id exists. |

## 12. Error handling

**Provider errors are not HTTP errors.** The V2 APIs answer HTTP 200 and put the verdict in the
body (§5.1). The adapter must map body codes to our states and to user-facing messages:

| Cashfree signal | Our state | User-facing message |
|---|---|---|
| `status = SUCCESS`, `status_code = COMPLETED` | `paid` | "₹102.50 sent to name@bank." |
| `status = RECEIVED` | `processing` | "Your payout is on its way." |
| `sub_code = INVALID_BENE_VPA` | `failed` | "We couldn't find that UPI ID. Please check it and try again." |
| `sub_code = INSUFFICIENT_BALANCE` | `failed` | "Our payout account needs a top-up. Your balance is safe — try again shortly." |
| `sub_code = DEST_LIMIT_BREACHED` / `DEST_LIMIT_REACHED` | `failed` | "That amount is above the UPI limit. Try a smaller amount." |
| `sub_code = BENE_BANK_DECLINED` / `SOURCE_BANK_DECLINED` | `failed` | "Your bank declined the transfer. Try another UPI ID." |
| `sub_code = NPCI_UNAVAILABLE` | `failed` (retryable) | "The UPI network is busy. Your balance is safe — try again shortly." |
| `sub_code = REINITIALIZE_TRANSFER_LATER` | `failed` (retryable) | "The transfer was queued for later." |
| `sub_code = ACCOUNT_BLOCKED` / `AUTHENTICATION_FAILURE` | `failed` | "Payouts are temporarily unavailable." (page the operator — this one means our own account is blocked.) |
| 403 "payment instrument does not support this mode of transfer" | `failed` | "UPI payouts are temporarily unavailable." (§5.2 — a fund-source configuration problem, not a user problem.) |

A retryable failure must not consume the user's money: the row goes terminal (`failed`), the
reservation is released, and the user can request again.

## 13. Test plan

**Unit**

- VPA format validation: valid forms (`name@bank`, `9876543210@okaxis`), invalid ones (no `@`,
  spaces, over-long handle, multiple `@`).
- FX maths: rounding at 2dp, the ₹100 floor, the ₹1,00,000 cap, and the "you need ₹X more"
  shortfall message.
- Reservation arithmetic: settled − in-flight, and release on every terminal state.
- State transitions: every legal edge, and the illegal ones (terminal → terminal) being refused.
- Webhook signature verification: a valid signature, a tampered body, a wrong key, a stale
  timestamp, a missing header.

**Integration (Cashfree sandbox)**

- Validate Payout against a known-good sandbox VPA and a known-bad one; assert that the bad one
  returns HTTP 200 with `account_status = INVALID` and an empty token, and that our adapter
  treats it as a failure rather than a success.
- Process Validated Payout end to end; assert the row reaches `paid`.
- Reusing a `transfer_id`; assert we get a 409 and our own unique index also holds.
- Sending a transfer **without** `fundsource_id`; assert we surface the "payment instrument does
  not support this mode of transfer" error clearly rather than failing opaquely (§5.2).
- A transfer above ₹1,00,000; assert it splits rather than failing.
- A webhook replayed twice; assert the second one changes nothing.
- A webhook with a bad signature; assert `401` and no ledger change.
- A webhook for an unknown `transfer_id`; assert `200` and no error (§9 step 4).

**End to end**

- A user with $2.40 of settled earnings requests a payout; assert exactly one payout row, the
  right INR amount at the snapshot rate, and the balance reduced by exactly the reserved USD.
- Two concurrent payout requests for the same user; assert the second cannot over-reserve.
- A payout whose provider call times out; assert the reservation is released and the money is
  spendable again.

## 14. Dashboard UI

`https://chatwait.com/dashboard/payouts` — a new tab alongside the existing dashboard.

**Payout method panel**

- A masked list of saved VPAs with status chips (`Verified` / `Needs confirmation` / `Rejected`).
- "Add UPI ID" form: a single input with inline validation. On submit, show the
  beneficiary name Cashfree resolved and ask the user to confirm it is theirs
  (*"We found **NAME AS PER UPI RECORDS** for this UPI ID. Is that you?"*). Only on
  confirmation does the account become `verified`.
- Reject inline: "That doesn't look like a UPI ID" (format), "We couldn't find that UPI ID"
  (provider `INVALID`), "Too many attempts — try again in an hour" (rate limit).

**Withdraw panel**

- Available balance in USD, the rate, and the resulting INR amount, refreshed live.
- Below ₹100: the button is disabled and the copy says how much more is needed
  (*"You need ₹12.40 more to withdraw."*).
- The user picks a verified VPA and confirms. The amount is not editable — the server decides.
- The confirmation screen shows the exact INR amount, the rate used, and the VPA masked.

**History list**

- Amount, date, status, and the Cashfree reference. A failed payout shows a plain-language
  reason and a "Try again" action.

**PII handling**

- The full VPA appears only in the active payment form. Everywhere else it is masked.
- The VPA is never put in a URL, never sent to analytics, and never logged in full.

## 15. Rollout

1. **Account setup** — create the Cashfree Payouts account, connect a bank account fund source
   (mandatory for UPI, §5.2), enable 2FA + IP whitelisting, and collect the sandbox credentials.
2. **Schema** — apply the migration; replace the `settled` CTE in the view with the real
   earnings query. Until that is done, `available_usd` is 0 for everyone and payouts are
   fail-closed — this is a useful safety property, not a bug.
3. **FX job** — schedule the daily rate write. Verify a row lands before anything else is
   enabled.
4. **Backend** — the Cashfree adapter, the two new endpoint groups, the webhook handler, the
   sweeper.
5. **Internal dogfood** — pay out to a handful of test VPAs in the sandbox, then in production
   with small amounts, before opening it to users.
6. **Dashboard UI** — behind a feature flag, so the flag can be flipped off without a deploy.
7. **Announce** — only after the fund source, the FX job and the sweeper have all been proven.

**Open items to resolve before implementation**

- **FX rate source.** Not chosen. It has to be a source that is (a) available from the
  backend, (b) legally usable for this purpose, and (c) stable enough to quote once and honour.
  The rate's timestamp and provider should be recorded alongside the value.
- **The real settled-earnings query** — the view's `settled` CTE is a placeholder; it must be
  pointed at whatever backs `GET /functions/v1/user-earnings`.
- **Whether `user_id` in the new tables should be a hard FK to `auth.users`.** The migration
  omits the FK because the backend's user table is not visible from this repo; add
  `references auth.users (id) on delete cascade` if that is the real table.
- **Whether the ₹100 floor should scale.** A fixed floor is simple but arbitrary; a
  percentage-of-balance floor may serve users better. It is a product decision, and the value is
  currently enforced in three places (the service constant, the SQL check, and the UI) — change
  all three together.
- **KYC.** Whether UPI payouts require a Cashfree Secure ID KYC check before a user can
  withdraw, and at what balance threshold. Not required for the flow to work; a compliance
  question.
- **Tax withholding / TDS.** Not addressed. If Indian withholding applies to creator payouts,
  it needs a place in the ledger and a line on the payout record.

## 16. Verification status of this document

- The migration was **executed against a real PostgreSQL** (PGlite 16, the PostgreSQL engine
  compiled to WASM) and 13 assertions pass: all three tables and the view are created, both
  `updated_at` triggers fire, the unique `transfer_id` rejects a duplicate, the `amount_inr >=
  100` check rejects a sub-floor payout, the status check rejects an invalid state, the
  `(user_id, upi_vpa)` uniqueness holds, the `fx_rates` rate check rejects a non-positive rate,
  the view is fail-closed before the earnings source is wired, the reservation arithmetic is
  correct (`5.00 − 1.23 = 3.77`) and releases on a terminal state, and the migration is
  re-runnable. Two real defects were found and fixed this way: a broken reference in the
  balance view, and a `now()`-based trigger that failed to advance `updated_at` for repeated
  updates within one transaction (now `clock_timestamp()`).
- **Every provider fact in §5 and §8 was read from Cashfree's live documentation on
  2026-10-21** — the Payouts overview, Beneficiary Management, Payout Methods, Lifecycle,
  Webhooks, and the V2 API reference for Validate Payout, Process Validated Payout, Create
  Beneficiary, Standard Transfer, Get Transfer Status and the V2 response codes. The
  documentation index is at `https://www.cashfree.com/docs/llms.txt`.
- **The endpoints and the auth scheme were verified against the live API** by probing it
  unauthenticated on 2026-10-21. `POST https://api.cashfree.com/payout/validatePayout`,
  `POST https://api.cashfree.com/payout/transfers` and
  `POST https://api.cashfree.com/payout/beneficiary` all exist on both the production and the
  sandbox base (each answers `400 x-client-id_missing` without credentials), and the sandbox
  equivalents exist on `https://sandbox.cashfree.com/payout/...`. The auth headers and their
  exact error shapes in §8 were read off those live responses. This corrected two errors in an
  earlier draft of this document: the base URL (Cashfree's per-endpoint OpenAPI blocks still
  list the V1 hosts) and the auth scheme (V2 takes `x-client-id`/`x-client-secret` headers, not
  a bearer token).
- **Not verified here:** the Cashfree account setup, the fund-source configuration, the live
  webhook signature round-trip, and every behaviour of the sandbox itself. Those need the
  real account and are in the test plan (§13).

## 17. Reference

- [Payouts overview](https://www.cashfree.com/docs/payouts/payouts/introduction)
- [Beneficiary management](https://www.cashfree.com/docs/payouts/payouts/beneficiaries-management)
- [Payout methods (UPI limits, fund-source restriction)](https://www.cashfree.com/docs/payouts/payouts/make-payouts/payout-methods)
- [Transfer lifecycle](https://www.cashfree.com/docs/payouts/payouts/make-payouts/lifecycle)
- [Webhooks and signature verification](https://www.cashfree.com/docs/payouts/payouts/make-payouts/webhooks)
- [Validate Payout API](https://www.cashfree.com/docs/api-reference/payouts/v2/validate-payout-v2)
- [Process Validated Payout API](https://www.cashfree.com/docs/api-reference/payouts/v2/verify-and-pay-transfers-v2)
- [V2 response codes](https://www.cashfree.com/docs/api-reference/payouts/v2/response-codes)
- [Go-live checklist](https://www.cashfree.com/docs/payouts/payouts/integrations/payouts-go-live)
