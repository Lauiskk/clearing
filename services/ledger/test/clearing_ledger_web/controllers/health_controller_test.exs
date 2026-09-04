defmodule Clearing.LedgerWeb.HealthControllerTest do
  use Clearing.LedgerWeb.ConnCase, async: false

  test "GET /healthz answers without touching the database", %{conn: conn} do
    assert %{"status" => "ok", "service" => "ledger"} =
             conn |> get(~p"/healthz") |> json_response(200)
  end

  test "GET /readyz checks the database", %{conn: conn} do
    assert %{"status" => "ok", "database" => "ok"} =
             conn |> get(~p"/readyz") |> json_response(200)
  end

  test "an unknown route gets the same error shape as everything else", %{conn: conn} do
    # A client should only ever have to learn one error shape, including for
    # routes this service does not have.
    assert %{"error" => %{"code" => "not_found", "message" => _}} =
             conn |> get("/v1/nothing-here") |> json_response(404)
  end
end
