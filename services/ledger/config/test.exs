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
  # Deliberately low-entropy and self-describing. Phoenix generates a random
  # 64-byte value here, which a secret scanner cannot tell apart from a real
  # leak -- so every run reports a finding, and a scanner that always cries
  # wolf is a scanner nobody reads. This value signs nothing: there are no
  # sessions or tokens in this service, it is never used outside test, and
  # config/runtime.exs raises unless SECRET_KEY_BASE is set in production.
  secret_key_base: "test_only_not_a_secret_test_only_not_a_secret_test_only_not_a_secret_",
  server: false

# An account process that has been idle this long stops and gives its memory
# back. Short in test so the suite does not end up holding one process per
# account it ever touched; see Clearing.Ledger.Accounts.Server.
config :clearing_ledger, :account_idle_timeout_ms, 5_000

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true
