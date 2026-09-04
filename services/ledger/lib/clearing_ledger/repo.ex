defmodule Clearing.Ledger.Repo do
  use Ecto.Repo,
    otp_app: :clearing_ledger,
    adapter: Ecto.Adapters.Postgres
end
