defmodule Clearing.Ledger.Fixtures do
  @moduledoc """
  Test data built by going through the real domain functions.

  Inserting rows directly would be faster and would let a fixture drift from
  the rules that govern real accounts -- a fixture could hold a balance no
  posting could ever produce, and the test built on it would pass while the
  system was broken.
  """

  alias Clearing.Ledger.Accounts
  alias Clearing.Ledger.Postings

  @doc "Opens an account. Pass `kind: \"house\"` for one allowed to go negative."
  def account(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, account} =
      %{
        "external_id" => "acct-#{unique}",
        "name" => "Account #{unique}",
        "currency" => "BRL",
        "kind" => "user"
      }
      |> Map.merge(stringify(attrs))
      |> Accounts.open()

    account
  end

  @doc """
  An account holding `amount_minor`, funded the only way money enters this
  ledger: a balanced posting against an `external` account.
  """
  def funded_account(amount_minor, attrs \\ %{}) do
    account = account(attrs)
    fund(account, amount_minor)
    account
  end

  @doc "Moves `amount_minor` into `account` from outside the system."
  def fund(account, amount_minor) do
    source = account(%{"kind" => "external", "currency" => account.currency})

    {:ok, transaction, :posted} =
      Postings.post(%{
        "idempotency_key" => key(),
        "kind" => "deposit",
        "entries" => [
          %{"account_id" => source.id, "amount_minor" => -amount_minor},
          %{"account_id" => account.id, "amount_minor" => amount_minor}
        ]
      })

    transaction
  end

  @doc "A fresh idempotency key, long enough to pass validation."
  def key, do: "idem-#{System.unique_integer([:positive])}-#{:erlang.unique_integer([:positive])}"

  defp stringify(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
