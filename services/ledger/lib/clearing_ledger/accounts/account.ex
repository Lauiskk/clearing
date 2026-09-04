defmodule Clearing.Ledger.Accounts.Account do
  @moduledoc """
  An account holds one currency and belongs to one of three kinds.

  `allow_negative` is not an input. It follows from `kind`, because whether an
  account may go negative is a property of what the account is *for* -- a
  customer balance never may, the system's own accounts must be able to -- and
  making it a field a caller can set is making it a field a caller can get
  wrong.
  """

  use Clearing.Ledger.Schema

  alias Clearing.Ledger.Accounts.Balance
  alias Clearing.Ledger.Money

  @kinds ~w(user house external)

  @type t :: %__MODULE__{}

  schema "accounts" do
    field :external_id, :string
    field :name, :string
    field :currency, :string
    field :kind, :string
    field :allow_negative, :boolean, default: false

    has_one :balance, Balance

    timestamps()
  end

  @doc "Every account kind this ledger recognises."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:external_id, :name, :currency, :kind])
    |> validate_required([:external_id, :name, :currency, :kind])
    |> validate_length(:external_id, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:kind, @kinds)
    |> validate_currency()
    |> derive_allow_negative()
    |> unique_constraint(:external_id)
  end

  defp validate_currency(changeset) do
    validate_change(changeset, :currency, fn :currency, currency ->
      if Money.known?(currency),
        do: [],
        else: [currency: "is not a currency this ledger accepts"]
    end)
  end

  defp derive_allow_negative(changeset) do
    case get_field(changeset, :kind) do
      nil -> changeset
      "user" -> put_change(changeset, :allow_negative, false)
      _house_or_external -> put_change(changeset, :allow_negative, true)
    end
  end
end
