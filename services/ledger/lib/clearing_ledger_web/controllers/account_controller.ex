defmodule Clearing.LedgerWeb.AccountController do
  use Clearing.LedgerWeb, :controller

  alias Clearing.Ledger.Accounts

  action_fallback Clearing.LedgerWeb.FallbackController

  def create(conn, params) do
    with {:ok, account} <- Accounts.open(params) do
      {:ok, balance} = Accounts.balance(account.id)

      conn
      |> put_status(:created)
      |> render(:show, account: account, balance: balance)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, account} <- Accounts.fetch(id),
         {:ok, balance} <- Accounts.balance(account.id) do
      render(conn, :show, account: account, balance: balance)
    end
  end

  def balance(conn, %{"id" => id}) do
    with {:ok, account} <- Accounts.fetch(id),
         {:ok, balance} <- Accounts.balance(account.id) do
      render(conn, :balance, account: account, balance: balance)
    end
  end

  def entries(conn, %{"id" => id} = params) do
    with {:ok, account} <- Accounts.fetch(id) do
      entries = Accounts.statement(account.id, limit: limit(params))
      render(conn, :entries, account: account, entries: entries)
    end
  end

  # An unparseable limit falls back to the default rather than 400-ing: the
  # caller asked for a page of a statement, and giving them one is more useful
  # than refusing over a query string.
  defp limit(%{"limit" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> limit
      _ -> 50
    end
  end

  defp limit(_params), do: 50
end
