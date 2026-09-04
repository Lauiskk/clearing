# 0001 — Elixir and Go, and which part gets which

**Status:** accepted · **Date:** 2026-09-04

## Context

The brief asks for a distributed system in Elixir *and* Go. Two runtimes in one
system is a cost — two toolchains, two test setups, two sets of idioms for the
same resilience problems — so the split has to be justified per service, not
declared once and assumed.

## Decision

**Elixir** takes the services whose hard problem is *stateful coordination*:

- `ledger` — a process per account, holding its balance and serialising the
  postings against it. `DynamicSupervisor` + `Registry` give process-per-entity
  with on-demand start, idle shutdown and supervised restart as library
  behaviour rather than as code to write.
- `orchestrator` — one supervised process per in-flight saga. A crash mid-saga
  is an ordinary restart from persisted state, not an exception path.
- `control` — the registry, holding cluster health in ETS and replicating it
  over BEAM distribution.

**Go** takes the services whose hard problem is *request throughput under a
deadline*:

- `edge` — a proxy. `context.Context` makes a deadline an explicit value every
  call must respect, which is exactly what a proxy needs and what the BEAM
  makes you assemble by hand.
- `risk` — a synchronous scorer where predictable latency matters more than
  supervision.

## What this is not

It is not "Elixir for the fun parts". If the whole system were Go, the ledger
would need an explicit lock manager keyed by account, a goroutine lifecycle to
manage and a supervision strategy to invent — which is exactly what
`Clearing.Ledger.Accounts.Server` is, written out, because even in Elixir that
part is not free. What OTP removes is the registry, the restart semantics and
the monitoring. What it does not remove is deciding the lock ordering, which is
why `Clearing.Ledger.Postings` sorts account ids before acquiring anything.

Equally, it is not "Go because it is fast". The ledger is not slow in Elixir.
The split is about which failure model each part wants: *let it crash and be
restarted with state reloaded* for the stateful services, *fail this request
inside its deadline and move on* for the request path.

## Consequences

- Two CI jobs, two Dockerfile shapes, two dependency audits.
- The resilience primitives — retry budget, circuit breaker, deadline
  propagation, discovery client — have to exist twice. ADR 0003 will compare
  the two implementations, which is the part of this repository worth reading.
- A developer needs both toolchains to run the whole stack. `task check` runs
  both, so the gate stays one command.
