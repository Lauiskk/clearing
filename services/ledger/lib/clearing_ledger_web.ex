defmodule Clearing.LedgerWeb do
  @moduledoc """
  The entrypoint for defining the web interface.

      use Clearing.LedgerWeb, :controller
      use Clearing.LedgerWeb, :router

  Keep these short: they are executed for every controller and router in the
  application, so anything defined here is compiled into all of them.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      # JSON only. There is no browser on the other end of this service.
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Clearing.LedgerWeb.Endpoint,
        router: Clearing.LedgerWeb.Router,
        statics: []
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/router/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
