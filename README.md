# clearing

A distributed payments platform in **Elixir and Go**: a double-entry ledger, a
saga orchestrator, a service registry with real health semantics, and an edge
that balances load by latency and sheds it when a dependency stops answering.

It exists to answer one question with a number rather than an adjective:

> Kubernetes gives you L4 round-robin and restart-on-crash. Is that enough?

Delete a pod under load and kube-proxy keeps routing to it until the readiness
probe fails and the endpoint change propagates. The same experiment against an
application-level mesh — leases carrying health *states*, latency-aware
balancing, a breaker per instance — is absorbed far faster. This repository
builds both, runs identical chaos experiments against each, and publishes the
comparison in [`docs/benchmarks.md`](docs/benchmarks.md).

---

## Status

Built in phases, each one shippable on its own. **Phase 1 of 8 is done.**

| | Phase | State |
|---|---|---|
| 1 | `ledger` — double-entry, idempotency, per-account serialisation | **done** |
| 2 | `control` — registry, TTL leases, health states, SSE watch; `edge` routing through it | next |
| 3 | `risk` + latency-aware balancing, circuit breaker, retry budget, deadlines | |
| 4 | `orchestrator` — saga with compensation, transactional outbox | |
| 5 | Distributed tracing across both runtimes | |
| 6 | Kubernetes: manifests, Helm, k3d, and the comparison above | |
| 7 | AWS: Terraform for RDS. Written in full, never applied | |
| 8 | Case study on the portfolio | |

Nothing in this README describes something that is not in the repository.

## The ledger

Money is an integer count of minor units and nothing else — no floats, no
decimal strings passed between functions. Entries are append-only. A mistake is
corrected by posting its reversal, never by editing history.

Three invariants are enforced **in Postgres**, not only in Elixir, so they hold
for a migration, a `psql` session and any future service:

- the entries of a transaction sum to zero **per currency**, checked once at
  `COMMIT` by a `DEFERRABLE INITIALLY DEFERRED` constraint trigger — every
  intermediate state of a transfer is unbalanced, so an eager check would
  reject every correct posting;
- an entry's currency must match the account it lands on;
- a `user` account's balance may not go negative, while `house` and `external`
  accounts must be able to — that is what it means for the system to owe
  someone.

Concurrency is a process per account, started on demand, holding its balance in
memory and serialising the postings against it. A posting sorts the account ids
before acquiring, so every posting in the system takes its locks in the same
global order and two of them can never each hold what the other wants. A holder
that crashes is released by a monitor; a caller that gives up waiting takes its
own grant back. `docs/decisions/0001-why-elixir-and-go.md` argues why this is a
process rather than `SELECT … FOR UPDATE`, including what it costs.

The balance table is a cache of the entries. `Accounts.reconcile/0` finds any
account where the two disagree, and the test suite asserts it returns nothing
after arbitrary concurrent load — which is what makes the cache safe to read.

### Proven, not asserted

```
  property   no random sequence of transfers changes the total: every balance
             in the ledger always sums to zero
  concurrency 20 concurrent requests against a 10,000 balance, 1,000 each:
             exactly 10 post, exactly 10 are refused, the balance lands on 0
  idempotency the same request twice posts once; the same key with a different
             body is 409, never a silent replay of the wrong amount
  liveness   a process killed while holding a lock does not wedge the account
```

`mix test` — 82 tests, 3 properties, 9 doctests, against a real Postgres.

## Running it

Needs Elixir 1.17 / OTP 27 and a Postgres. No Docker required for this phase.

```bash
cp .env.example .env     # only if your Postgres is not on localhost:5432
task setup               # deps, database, migrations
task ledger              # http://127.0.0.1:4010
task check               # format, compile -Werror, credo, sobelow, tests
```

```bash
# Open an account, fund it from outside the system, move some money.
curl -XPOST localhost:4010/v1/accounts -H 'content-type: application/json' \
  -d '{"external_id":"alice","name":"Alice","currency":"BRL","kind":"user"}'

curl -XPOST localhost:4010/v1/transfers -H 'content-type: application/json' \
  -d '{"idempotency_key":"transfer-0001","from":"<uuid>","to":"<uuid>",
       "amount_minor":12345,"reference":"pizza"}'
```

Every amount goes out twice: `amount_minor` is the integer to compute with,
`amount` is the same number rendered for a human. Every error has a stable
code — `insufficient_funds`, `idempotency_conflict`, `unbalanced`,
`unknown_account`, `busy` — because a payments client branches on the code, not
on the prose.

## Layout

```
services/ledger/     Elixir · Phoenix 1.8 API-only · Ecto · the double-entry core
docs/decisions/      why things are the way they are, including what they cost
.github/workflows/   the same commands Taskfile runs
```

## Licence

MIT.
