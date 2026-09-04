defmodule Clearing.LedgerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :clearing_ledger

  # This is a JSON service with no browser in front of it, so the generated
  # session, static-file and method-override plugs are gone. Every plug left
  # here earns its place: a request id to correlate logs across services,
  # telemetry, a body parser, and HEAD support.
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    # A ledger posting is a handful of entries. A body larger than this is a
    # mistake or an attack, and either way is cheaper to refuse than to parse.
    length: 1_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug Clearing.LedgerWeb.Router
end
