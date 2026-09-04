defmodule Clearing.LedgerWeb.AccountJSON do
  @moduledoc """
  Every amount goes out twice: `amount_minor` is the canonical integer a client
  should compute with, and `amount` is the same number rendered for a human to
  read. Sending only the string would invite clients to parse it back into a
  float, which is the bug this ledger is built to avoid.
  """

  alias Clearing.Ledger.Money

  def show(%{account: account, balance: balance}) do
    %{data: Map.put(account(account), :balance, amounts(balance))}
  end

  def balance(%{account: account, balance: balance}) do
    %{data: Map.merge(%{account_id: account.id}, amounts(balance))}
  end

  def entries(%{account: account, entries: entries}) do
    %{data: %{account_id: account.id, entries: Enum.map(entries, &entry/1)}}
  end

  defp account(account) do
    %{
      id: account.id,
      external_id: account.external_id,
      name: account.name,
      currency: account.currency,
      kind: account.kind,
      allow_negative: account.allow_negative,
      opened_at: account.inserted_at
    }
  end

  defp amounts(balance) do
    %{
      amount_minor: balance.amount_minor,
      amount: rendered(balance.amount_minor, balance.currency),
      currency: balance.currency,
      version: balance.version
    }
  end

  defp entry(entry) do
    %{
      id: entry.id,
      transaction_id: entry.transaction_id,
      amount_minor: entry.amount_minor,
      amount: rendered(entry.amount_minor, entry.currency),
      currency: entry.currency,
      posted_at: entry.inserted_at
    }
  end

  defp rendered(minor, currency) do
    case Money.format(minor, currency) do
      {:ok, text} -> text
      :error -> nil
    end
  end
end
