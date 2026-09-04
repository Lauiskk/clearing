defmodule Clearing.LedgerWeb.AccountControllerTest do
  use Clearing.LedgerWeb.ConnCase, async: false

  alias Clearing.Ledger.Fixtures

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "POST /v1/accounts" do
    test "opens an account with a zero balance", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/accounts", %{
          "external_id" => "wallet-9",
          "name" => "Wallet",
          "currency" => "BRL",
          "kind" => "user"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["external_id"] == "wallet-9"
      assert data["currency"] == "BRL"
      assert data["allow_negative"] == false
      assert data["balance"]["amount_minor"] == 0
      assert data["balance"]["amount"] == "0.00"
      assert data["balance"]["version"] == 0
    end

    test "refuses an unknown currency with a code a client can branch on", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/accounts", %{
          "external_id" => "x",
          "name" => "X",
          "currency" => "XYZ",
          "kind" => "user"
        })

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 422)

      assert message =~ "currency"
    end

    test "refuses a duplicate external id", %{conn: conn} do
      _existing = Fixtures.account(%{external_id: "taken"})

      conn =
        post(conn, ~p"/v1/accounts", %{
          "external_id" => "taken",
          "name" => "Other",
          "currency" => "BRL",
          "kind" => "user"
        })

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(conn, 422)
    end
  end

  describe "GET /v1/accounts/:id" do
    test "returns the account and its balance", %{conn: conn} do
      account = Fixtures.funded_account(12_345)

      conn = get(conn, ~p"/v1/accounts/#{account.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == account.id
      assert data["balance"]["amount_minor"] == 12_345
      assert data["balance"]["amount"] == "123.45"
    end

    test "is a 404 for an id that does not exist, and for one that is not an id", %{conn: conn} do
      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        conn = get(conn, ~p"/v1/accounts/#{id}")
        assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
      end
    end
  end

  describe "GET /v1/accounts/:id/balance" do
    test "returns just the balance", %{conn: conn} do
      account = Fixtures.funded_account(500)

      conn = get(conn, ~p"/v1/accounts/#{account.id}/balance")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["account_id"] == account.id
      assert data["amount_minor"] == 500
      assert data["amount"] == "5.00"
    end
  end

  describe "GET /v1/accounts/:id/entries" do
    test "returns the statement newest first", %{conn: conn} do
      account = Fixtures.funded_account(100)
      Fixtures.fund(account, 200)

      conn = get(conn, ~p"/v1/accounts/#{account.id}/entries")

      assert %{"data" => %{"entries" => entries}} = json_response(conn, 200)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1["currency"] == "BRL"))
    end

    test "honours a limit, and ignores one that is nonsense", %{conn: conn} do
      account = Fixtures.funded_account(100)
      Fixtures.fund(account, 200)

      assert %{"data" => %{"entries" => [_one]}} =
               conn |> get(~p"/v1/accounts/#{account.id}/entries?limit=1") |> json_response(200)

      assert %{"data" => %{"entries" => entries}} =
               conn |> get(~p"/v1/accounts/#{account.id}/entries?limit=abc") |> json_response(200)

      assert length(entries) == 2
    end
  end
end
