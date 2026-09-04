import Config

# See config/dev.exs for why the connection is read from the environment.
config :clearing_ledger, Clearing.Ledger.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "clearing_ledger_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :clearing_ledger, Clearing.LedgerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "d3MskZwO5r25JIEBdcY2veI5pKW0QPYFZm6WE2VB3Oto1vCx58VrRgI61bXHr+2d",
  server: false

# An account process that has been idle this long stops and gives its memory
# back. Short in test so the suite does not end up holding one process per
# account it ever touched; see Clearing.Ledger.Accounts.Server.
config :clearing_ledger, :account_idle_timeout_ms, 5_000

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true
