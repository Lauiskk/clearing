defmodule Clearing.Ledger.Accounts.Balance do
  @moduledoc """
  The running total for one account, maintained in the same transaction as the
  entries that move it.

  It is a cache. `entries` is the truth, and `Clearing.Ledger.Accounts.reconcile/0`
  exists to prove the two still agree. The cache is here because answering
  "what is this balance" by summing an account's whole history is fine on day
  one and unusable on day four hundred.

  `version` is optimistic-concurrency insurance. Postings hold an in-process
  lock on the account, so a conflicting update should be impossible -- which is
  the point. If the lock manager is ever wrong, this turns a silently corrupted
  balance into a failed transaction.
  """

  use Ecto.Schema

  alias Clearing.Ledger.Accounts.Account

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "balances" do
    belongs_to :account, Account, primary_key: true
    field :amount_minor, :integer, default: 0
    field :currency, :string
    field :allow_negative, :boolean
    field :version, :integer, default: 0

    timestamps(inserted_at: false)
  end
end
