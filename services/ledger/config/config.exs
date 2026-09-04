# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :clearing_ledger,
  namespace: Clearing.Ledger,
  ecto_repos: [Clearing.Ledger.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :clearing_ledger, Clearing.LedgerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Clearing.LedgerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Clearing.Ledger.PubSub

# How long an idle account process lives before stopping. Long enough that a
# busy account keeps its cached balance hot, short enough that a million
# one-off accounts do not become a million resident processes.
config :clearing_ledger, :account_idle_timeout_ms, 60_000

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  # account_id and from come from the account lock manager's warnings. A key
  # that is not listed here is silently dropped, which turns a diagnostic into
  # a sentence with the diagnosis missing.
  metadata: [:request_id, :account_id, :from]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
