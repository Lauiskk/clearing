defmodule Clearing.LedgerWeb.PostingJSON do
  @moduledoc false

  alias Clearing.Ledger.Money

  def show(%{transaction: transaction, outcome: outcome}) do
    %{
      data: %{
        id: transaction.id,
        idempotency_key: transaction.idempotency_key,
        kind: transaction.kind,
        reference: transaction.reference,
        reverses_id: transaction.reverses_id,
        posted_at: transaction.inserted_at,
        # Whether this response is the result of new work or of a replay. A
        # client retrying after a timeout can tell which of its attempts landed.
        outcome: outcome,
        entries: Enum.map(transaction.entries, &entry/1)
      }
    }
  end

  defp entry(entry) do
    %{
      id: entry.id,
      account_id: entry.account_id,
      amount_minor: entry.amount_minor,
      amount: rendered(entry.amount_minor, entry.currency),
      currency: entry.currency
    }
  end

  defp rendered(minor, currency) do
    case Money.format(minor, currency) do
      {:ok, text} -> text
      :error -> nil
    end
  end
end
