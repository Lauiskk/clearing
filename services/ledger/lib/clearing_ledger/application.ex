defmodule Clearing.Ledger.Application do
  @moduledoc false

  use Application

  alias Clearing.Ledger.Accounts
  alias Clearing.LedgerWeb.Endpoint

  @impl Application
  def start(_type, _args) do
    children = [
      Clearing.LedgerWeb.Telemetry,
      Clearing.Ledger.Repo,
      {DNSCluster, query: Application.get_env(:clearing_ledger, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Clearing.Ledger.PubSub},

      # The registry must be up before the supervisor that registers into it,
      # and both before the endpoint that will send them work.
      {Registry, keys: :unique, name: Accounts.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Accounts.Supervisor},
      Endpoint
    ]

    # :one_for_one, not :rest_for_one. An account process crashing is ordinary
    # -- it is restarted on demand by the next caller, having reloaded its
    # balance from the database -- and must not take the endpoint with it.
    Supervisor.start_link(children, strategy: :one_for_one, name: Clearing.Ledger.Supervisor)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
