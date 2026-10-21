-- Chatwait — UPI payouts (Cashfree Payouts v2)
--
-- Target: the private source-of-truth repo (chatwait web app + api.chatwait.com backend).
-- This file is a spec artifact for the backend; it does NOT belong in the public
-- extension mirror, which ships no payout code.
--
-- Provider facts this schema depends on (verified against Cashfree docs):
--   - UPI transfers are per-transaction capped at Rs. 1,00,000 (bank-dependent:
--     Rs. 10,000 - Rs. 1,00,000). See "Payout Methods".
--   - UPI is NOT payable from the Payout Wallet (CF_WALLET) fund source — a connected
--     bank account must be the fund source. See "Payout Methods" (platform-level
--     restriction: "The transfer has been rejected because the payment instrument
--     does not support this mode of transfer").
--   - The V2 APIs answer HTTP 200 even for failures; the verdict lives in the body
--     (`status` / `status_code` / `sub_code`). See "Response Codes" (V2).
--
-- Naming: `upi_vpa` is the full VPA (`name@bank`); it is PII and must never be logged
-- in full, echoed in URLs, or stored in any page-local storage.

begin;

-- ---------------------------------------------------------------------------
-- fx_rates — daily USD->INR snapshot.
--
-- The rate is snapshotted when a payout is REQUESTED and then frozen on the
-- payouts row, so the INR amount the user agreed to cannot drift after the fact.
-- Populate this daily (cron / scheduled edge function) BEFORE enabling payouts:
-- a missing row must fail the payout request, never silently fall back to 1.0.
-- ---------------------------------------------------------------------------
create table if not exists fx_rates (
  base_currency   text                 not null default 'USD',
  quote_currency  text                 not null default 'INR',
  rate            numeric(20, 10)      not null,
  as_of           date                 not null,
  primary key (base_currency, quote_currency, as_of),
  constraint fx_rates_rate_positive check (rate > 0)
);

comment on table fx_rates is
  'Daily FX snapshots. A payout reads the latest as_of <= today and copies rate onto the payouts row.';

-- ---------------------------------------------------------------------------
-- payout_accounts — a user's saved UPI destination and its verification state.
--
-- `status` is deliberately NOT flipped to 'verified' by a client action. The only
-- thing that promotes an account is a successful Cashfree Validate Payout
-- (POST /payout/validatePayout) that returns account_status = VALID together
-- with a non-empty transfer_token, AND the user confirming the beneficiary name
-- Cashfree resolved for that VPA. The user's own "I paid the verification
-- charge" click is never authoritative.
-- ---------------------------------------------------------------------------
create table if not exists payout_accounts (
  id                uuid        primary key default gen_random_uuid(),
  user_id           uuid        not null,
  method            text        not null default 'upi',
  upi_vpa           text        not null,
  beneficiary_name  text,
  status            text        not null default 'pending_verification',
  verified_at       timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint payout_accounts_method_upi check (method = 'upi'),
  constraint payout_accounts_status_valid
    check (status in ('pending_verification', 'verified', 'rejected')),
  -- One saved destination per VPA per user: re-adding the same VPA re-verifies it
  -- rather than creating a second row that could be paid against independently.
  constraint payout_accounts_user_vpa_unique unique (user_id, upi_vpa)
);

create index if not exists payout_accounts_user_idx
  on payout_accounts (user_id, created_at desc);

comment on column payout_accounts.upi_vpa is
  'Full UPI VPA (name@bank). PII — never log in full, never place in a URL, never write to page storage.';
comment on column payout_accounts.beneficiary_name is
  'Beneficiary name resolved by Cashfree for this VPA, shown back to the user for confirmation.';

-- ---------------------------------------------------------------------------
-- payouts — the money ledger.
--
-- `transfer_id` is our idempotency key and is passed verbatim to Cashfree as
-- their transfer_id: their API answers 409 "Transfer Id already exists" for a
-- repeat, and this unique index makes the guarantee ours independently.
--
-- `amount_usd` is what we reserved from the user's settled earnings;
-- `amount_inr` is what the user receives. Both are frozen at request time.
--
-- `fx_rate` is the snapshot actually used, so a later rate move never changes
-- an already-agreed payout.
-- ---------------------------------------------------------------------------
create table if not exists payouts (
  id                uuid           primary key default gen_random_uuid(),
  user_id           uuid           not null,
  payout_account_id uuid           not null references payout_accounts (id) on delete restrict,
  amount_usd        numeric(20, 10) not null,
  fx_rate           numeric(20, 10) not null,
  amount_inr        numeric(18, 2)  not null,
  status            text           not null default 'requested',
  transfer_id       text           not null,
  cf_transfer_id    text,
  failure_code      text,
  failure_message   text,
  requested_at      timestamptz    not null default now(),
  settled_at        timestamptz,
  created_at        timestamptz    not null default now(),
  updated_at        timestamptz    not null default now(),
  constraint payouts_amount_usd_positive check (amount_usd > 0),
  constraint payouts_fx_rate_positive check (fx_rate > 0),
  -- Rs. 100 floor (product decision, 2026-10-21). If the minimum ever changes,
  -- change it here in the same commit as the constant in the payout service.
  constraint payouts_amount_inr_minimum check (amount_inr >= 100),
  constraint payouts_status_valid check (
    status in ('requested', 'validated', 'processing', 'paid', 'failed', 'rejected', 'reversed')
  ),
  -- Idempotency: one Cashfree transfer per payout row, ever.
  constraint payouts_transfer_id_unique unique (transfer_id)
);

create index if not exists payouts_user_idx
  on payouts (user_id, created_at desc);

-- Supports the reconciliation sweeper that finds payouts stuck in a
-- non-terminal state (Cashfree never called back, or a webhook was lost).
create index if not exists payouts_open_idx
  on payouts (status, updated_at)
  where status in ('requested', 'validated', 'processing');

comment on table payouts is
  'Payout ledger. amount_usd is reserved from settled earnings until the row reaches a terminal state.';
comment on column payouts.transfer_id is
  'Our idempotency key, sent to Cashfree as transfer_id. Cashfree returns 409 on reuse.';
comment on column payouts.cf_transfer_id is
  'Cashfree-assigned transfer identifier, surfaced on their webhooks.';

-- ---------------------------------------------------------------------------
-- updated_at maintenance.
-- ---------------------------------------------------------------------------
create or replace function chatwait_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  -- clock_timestamp(), not now(): now() is transaction-scoped, so two updates inside
  -- one transaction would both stamp the same timestamp and updated_at would stop
  -- advancing. The reconciliation sweeper keys off updated_at, so it needs to move
  -- on every actual row change.
  new.updated_at := clock_timestamp();
  return new;
end;
$$;

drop trigger if exists payout_accounts_set_updated_at on payout_accounts;
create trigger payout_accounts_set_updated_at
  before update on payout_accounts
  for each row execute function chatwait_set_updated_at();

drop trigger if exists payouts_set_updated_at on payouts;
create trigger payouts_set_updated_at
  before update on payouts
  for each row execute function chatwait_set_updated_at();

-- ---------------------------------------------------------------------------
-- Available balance.
--
-- INTEGRATION POINT: `<settled_earnings>` below must be replaced with the real
-- earnings source in the private backend (the query behind GET
-- /functions/v1/user-earnings, which currently returns a `total_usd` figure).
-- The shape of the expression is what matters:
--
--   available_usd = settled earnings - sum(amount_usd) reserved by payouts that
--                   are still in flight (requested | validated | processing).
--
-- A payout row leaves the reserved set the moment it reaches a terminal state
-- (paid | failed | rejected | reversed). "failed" and "rejected" release the
-- reservation so the user can retry with the same money; "reversed" does too,
-- because Cashfree credits the amount back to the Payouts account.
-- ---------------------------------------------------------------------------
create or replace view payout_available_balances as
with settled as (
  -- INTEGRATION POINT: replace with the real settled-earnings query.
  -- Must return (user_id uuid, settled_usd numeric) — one row per user with a
  -- non-zero settled balance is enough. Until this is wired the CTE is empty,
  -- so settled_usd coalesces to 0 and available_usd can never be positive:
  -- payouts stay fail-closed rather than paying out money we cannot see.
  select cast(null as uuid) as user_id, cast(0 as numeric(20, 10)) as settled_usd
  where false
),
reserved as (
  select
    user_id,
    sum(amount_usd) as reserved_usd
  from payouts
  where status in ('requested', 'validated', 'processing')
  group by user_id
),
participants as (
  select user_id from payout_accounts
  union
  select user_id from payouts
)
select
  p.user_id,
  coalesce(s.settled_usd, 0) - coalesce(r.reserved_usd, 0) as available_usd
from participants p
left join settled s on s.user_id = p.user_id
left join reserved r on r.user_id = p.user_id;

commit;
