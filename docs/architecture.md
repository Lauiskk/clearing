# Architecture

## The shape

```
                                    ┌───────────────────────────────────┐
   client ──▶  edge  ──────────────▶│ orchestrator          (Elixir)    │
               (Go)                 │ saga: reserve → risk → settle →   │
                │                   │ notify, compensating in reverse   │
                │                   └──────┬─────────────────┬──────────┘
                │                          │                 │
                │                          ▼                 ▼
                │                     risk (Go)        ledger (Elixir)
                │                     limits, score    double entry
                │                          │                 │
                ▼                          │                 │
        control (Elixir)               risk_db          ledger_db    orch_db
        TTL leases, health              ──────────────────────────────────
        states, SSE watch               one Postgres, four databases, one
                ▲                       role each. Postgres will not cross
                │                       a database without FDW, so the
        every instance heartbeats       service boundary is structural
        here; every client watches      rather than a convention.
```

Deployed twice from the same code: `docker compose` for development, and
Kubernetes (k3d locally, manifests plus a Helm chart) for the comparison the
project exists to make.

## Data ownership

Database per service. They run on one Postgres instance so the stack starts on
a laptop, and each service connects as its own role with `CONNECT` on its own
database only. In production these would be separate instances; nothing in the
code would change.

Money is `bigint` minor units everywhere. `NUMERIC` invites division and
`double precision` cannot represent 0.1 — either one is a ledger that is wrong
in a decimal place nobody checks until settlement.

## What is enforced where

| Rule | Where | Why there |
|---|---|---|
| entries sum to zero per currency | deferred constraint trigger | holds for migrations and psql, not only for code |
| entry currency matches its account | row trigger | catches a class of corruption at insert |
| user accounts never go negative | check constraint on `balances` | the last line, if the in-memory check is ever wrong |
| idempotency | unique index on `idempotency_key` | the index *is* the mechanism |
| no double spend under concurrency | process-per-account lock, ordered acquisition | the balance is in memory; the ordering is what makes it safe |
| balance cache matches entries | `Accounts.reconcile/0` + tests | a cache with no way to check it is a liability |

## Failure model

Stateful services (`ledger`, `orchestrator`, `control`) follow *let it crash*:
state is either in Postgres or rebuildable from it, so a restarted process
reloads and continues. An account process that dies mid-posting takes its
database transaction with it and releases its lock through a monitor.

The request path (`edge`, `risk`) follows *fail inside the deadline*: a
deadline is set at the edge and decremented on every hop, and a service that
cannot finish inside the remaining budget refuses rather than doing work
nobody is still waiting for.
