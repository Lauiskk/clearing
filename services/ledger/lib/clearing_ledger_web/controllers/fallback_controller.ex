defmodule Clearing.LedgerWeb.FallbackController do
  @moduledoc """
  Turns every domain refusal into one stable machine-readable code.

  A payments client branches on the code, not the prose: `insufficient_funds`
  is something to show the user, `idempotency_conflict` is a bug to fix, and
  `busy` is worth retrying. A single `{"error": "..."}` string would make all
  three look the same.
  """

  use Clearing.LedgerWeb, :controller

  alias Clearing.Ledger.Money
  alias Clearing.LedgerWeb.ErrorJSON

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    respond(conn, :unprocessable_entity, "invalid_request", changeset_message(changeset))
  end

  def call(conn, {:error, {:invalid, field, message}}) do
    respond(conn, :unprocessable_entity, "invalid_request", "#{field} #{message}")
  end

  def call(conn, {:error, {:unknown_account, id}}) do
    respond(conn, :unprocessable_entity, "unknown_account", "no account with id #{id}")
  end

  def call(conn, {:error, {:insufficient_funds, id}}) do
    respond(conn, :unprocessable_entity, "insufficient_funds", "account #{id} lacks the balance")
  end

  def call(conn, {:error, :unbalanced}) do
    respond(
      conn,
      :unprocessable_entity,
      "unbalanced",
      "the entries of a transaction must sum to zero in each currency"
    )
  end

  def call(conn, {:error, :idempotency_conflict}) do
    respond(
      conn,
      :conflict,
      "idempotency_conflict",
      "this idempotency key was already used for a different request"
    )
  end

  def call(conn, {:error, reason}) when reason in [:busy, :unavailable] do
    conn
    # Long enough to be past a lock hand-off, short enough that a caller with a
    # deadline still has room to use it.
    |> put_resp_header("retry-after", "1")
    |> respond(:service_unavailable, "busy", "the accounts involved are locked; retry")
  end

  def call(conn, {:error, :not_found}) do
    respond(conn, :not_found, "not_found", "no such resource")
  end

  defp respond(conn, status, code, message) do
    conn
    |> put_status(status)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: code, message: message)
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&render_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp render_error({message, opts}) do
    Regex.replace(~r/%\{(\w+)\}/, message, fn _whole, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end

  @doc "The currencies this ledger accepts, for error messages that list them."
  def currencies, do: Enum.join(Money.currencies(), ", ")
end
