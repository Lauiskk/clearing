defmodule Clearing.Ledger.Postings.Transaction do
  @moduledoc """
  One balanced movement of money: a header, plus the entries that sum to zero.

  `idempotency_key` is unique, which is the entire retry story. `request_digest`
  is what makes a replay honest -- the same key with a different body is a
  caller bug, and returning the original result would post the wrong money and
  hide the bug at the same time.
  """

  use Clearing.Ledger.Schema

  alias Clearing.Ledger.Postings.Entry

  @kinds ~w(transfer deposit withdrawal fee reversal)

  @type t :: %__MODULE__{}

  schema "transactions" do
    field :idempotency_key, :string
    field :kind, :string
    field :reference, :string
    field :request_digest, :binary

    belongs_to :reverses, __MODULE__
    has_many :entries, Entry

    timestamps(updated_at: false)
  end

  @doc "Every transaction kind this ledger recognises."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:idempotency_key, :kind, :reference, :request_digest, :reverses_id])
    |> validate_required([:idempotency_key, :kind, :request_digest])
    |> validate_length(:idempotency_key, min: 8, max: 255)
    |> validate_length(:reference, max: 255)
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:idempotency_key)
    |> foreign_key_constraint(:reverses_id)
  end
end
