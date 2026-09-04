defmodule Clearing.Ledger.Schema do
  @moduledoc """
  The schema defaults every table in this service shares: UUID primary keys,
  UUID foreign keys, and UTC timestamps.

  Setting them in one place means a new schema cannot quietly get an integer
  primary key because someone forgot the two module attributes.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      import Ecto.Changeset

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
