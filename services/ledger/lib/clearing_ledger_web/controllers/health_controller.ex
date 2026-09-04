defmodule Clearing.LedgerWeb.HealthController do
  @moduledoc """
  Liveness and readiness, which are not the same question.

  `/healthz` asks "is this process running" -- if it answers at all, the answer
  is yes, and a failing answer means the orchestrator should restart the pod.

  `/readyz` asks "should traffic come here", and it checks the database,
  because a service that cannot reach its database should be taken out of
  rotation rather than restarted. Restarting will not bring Postgres back.

  Phase 2 adds a third state to this: `draining`, reported to the registry so
  the load balancer stops sending new work while in-flight requests finish.
  """

  use Clearing.LedgerWeb, :controller

  alias Clearing.Ledger.Repo
  alias Ecto.Adapters.SQL

  @service "ledger"

  def live(conn, _params) do
    json(conn, %{status: "ok", service: @service})
  end

  def ready(conn, _params) do
    case database_reachable?() do
      :ok ->
        json(conn, %{status: "ok", service: @service, database: "ok"})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable", service: @service, database: reason})
    end
  end

  defp database_reachable? do
    case SQL.query(Repo, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, inspect(error.__struct__)}
    end
  rescue
    error -> {:error, inspect(error.__struct__)}
  end
end
