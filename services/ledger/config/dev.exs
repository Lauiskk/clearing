import Config

# Local Postgres, overridable by environment.
#
# A fresh clone runs `docker compose up` and gets 5432. This machine already
# has a system Postgres on 5433, and CI has its own service container. Reading
# the values from the environment means all three work without anyone editing
# a tracked file -- and `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD` are the names
# psql itself uses, so they are probably already set.
config :clearing_ledger, Clearing.Ledger.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "clearing_ledger_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :clearing_ledger, Clearing.LedgerWeb.Endpoint,
  # Loopback only. What reaches this service from outside is the edge, and in
  # compose that is another container on the same network.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "R4SJndKo3jNL18Rg0wVixtKynjMctYyLJQiCFLgsr4Nly1SPO+rWVdqXfUPadJ0T",
  watchers: []

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
