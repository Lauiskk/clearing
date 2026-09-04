defmodule Clearing.Ledger.Postings.Entry do
  @moduledoc """
  One side of one movement: an amount against an account.

  Append-only. There is no `updated_at` and no update path, because correcting
  a ledger by editing history is how you end up unable to explain a balance.
  A mistake is corrected by posting its reversal, and both stay on the record.
  """

  use Clearing.Ledger.Schema

  alias Clearing.Ledger.Accounts.Account
  alias Clearing.Ledger.Postings.Transaction

  @type t :: %__MODULE__{}

  schema "entries" do
    field :amount_minor, :integer
    field :currency, :string

    belongs_to :transaction, Transaction
    belongs_to :account, Account

    timestamps(updated_at: false)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:amount_minor, :currency, :transaction_id, :account_id])
    |> validate_required([:amount_minor, :currency, :transaction_id, :account_id])
    |> validate_exclusion(:amount_minor, [0], message: "must not be zero")
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:transaction_id)
  end
end
