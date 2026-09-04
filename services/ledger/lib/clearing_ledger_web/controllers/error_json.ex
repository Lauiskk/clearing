defmodule Clearing.LedgerWeb.ErrorJSON do
  @moduledoc """
  The one error shape this service emits: `{"error": {"code", "message"}}`.

  Phoenix renders unhandled statuses through `render/2` below, so a 404 from a
  route that does not exist looks exactly like a 404 from a resource that does
  not exist. A client only has to learn one shape.
  """

  @doc false
  def error(%{code: code, message: message}) do
    %{error: %{code: code, message: message}}
  end

  @doc false
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)

    %{
      error: %{
        code: template |> String.replace_suffix(".json", "") |> code_for(),
        message: status
      }
    }
  end

  defp code_for("404"), do: "not_found"
  defp code_for("405"), do: "method_not_allowed"
  defp code_for("415"), do: "unsupported_media_type"
  defp code_for("500"), do: "internal_error"
  defp code_for(status), do: "http_#{status}"
end
