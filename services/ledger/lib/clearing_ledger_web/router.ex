defmodule Clearing.LedgerWeb.Router do
  use Clearing.LedgerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Liveness and readiness sit outside /v1 and outside any versioning promise.
  # They are for the orchestrator, not for callers, and the two say different
  # things: /healthz means the process is running, /readyz means it can serve.
  # Conflating them gets a pod killed for a database blip it would recover from.
  scope "/", Clearing.LedgerWeb do
    pipe_through :api

    get "/healthz", HealthController, :live
    get "/readyz", HealthController, :ready
  end

  scope "/v1", Clearing.LedgerWeb do
    pipe_through :api

    post "/accounts", AccountController, :create
    get "/accounts/:id", AccountController, :show
    get "/accounts/:id/balance", AccountController, :balance
    get "/accounts/:id/entries", AccountController, :entries

    post "/postings", PostingController, :create
    post "/transfers", PostingController, :transfer
    get "/transactions/:id", PostingController, :show
  end
end
