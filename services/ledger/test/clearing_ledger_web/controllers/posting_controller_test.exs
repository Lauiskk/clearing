defmodule Clearing.LedgerWeb.PostingControllerTest do
  use Clearing.LedgerWeb.ConnCase, async: false

  alias Clearing.Ledger.Fixtures

  setup %{conn: conn} do
    conn = put_req_header(conn, "accept", "application/json")
    %{conn: conn, source: Fixtures.funded_account(10_000), destination: Fixtures.account()}
  end

  describe "POST /v1/transfers" do
    test "posts, and says it posted", %{conn: conn, source: source, destination: destination} do
      conn =
        post(conn, ~p"/v1/transfers", %{
          "idempotency_key" => Fixtures.key(),
          "from" => source.id,
          "to" => destination.id,
          "amount_minor" => 2_500,
          "reference" => "invoice-7"
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["outcome"] == "posted"
      assert data["kind"] == "transfer"
      assert data["reference"] == "invoice-7"
      assert length(data["entries"]) == 2
      assert Enum.sum(Enum.map(data["entries"], & &1["amount_minor"])) == 0
      assert Enum.find(data["entries"], &(&1["amount_minor"] == 2_500))["amount"] == "25.00"
    end

    test "a replay is a 200 that says so", %{conn: conn, source: source, destination: destination} do
      body = %{
        "idempotency_key" => Fixtures.key(),
        "from" => source.id,
        "to" => destination.id,
        "amount_minor" => 1_000
      }

      first = post(conn, ~p"/v1/transfers", body)
      assert json_response(first, 201)["data"]["outcome"] == "posted"

      second = post(conn, ~p"/v1/transfers", body)
      assert %{"data" => data} = json_response(second, 200)
      assert data["outcome"] == "replayed"
      assert data["id"] == json_response(first, 201)["data"]["id"]
    end

    test "the same key with a different body is 409", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      body = %{
        "idempotency_key" => Fixtures.key(),
        "from" => source.id,
        "to" => destination.id,
        "amount_minor" => 1_000
      }

      assert json_response(post(conn, ~p"/v1/transfers", body), 201)

      conn = post(conn, ~p"/v1/transfers", %{body | "amount_minor" => 2_000})
      assert %{"error" => %{"code" => "idempotency_conflict"}} = json_response(conn, 409)
    end

    test "an overdraft is 422 insufficient_funds", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      conn =
        post(conn, ~p"/v1/transfers", %{
          "idempotency_key" => Fixtures.key(),
          "from" => source.id,
          "to" => destination.id,
          "amount_minor" => 10_001
        })

      assert %{"error" => %{"code" => "insufficient_funds"}} = json_response(conn, 422)
    end

    test "an unknown account is 422 unknown_account", %{conn: conn, source: source} do
      conn =
        post(conn, ~p"/v1/transfers", %{
          "idempotency_key" => Fixtures.key(),
          "from" => source.id,
          "to" => Ecto.UUID.generate(),
          "amount_minor" => 100
        })

      assert %{"error" => %{"code" => "unknown_account"}} = json_response(conn, 422)
    end

    test "a missing amount is 422 invalid_request", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      conn =
        post(conn, ~p"/v1/transfers", %{
          "idempotency_key" => Fixtures.key(),
          "from" => source.id,
          "to" => destination.id
        })

      assert %{"error" => %{"code" => "invalid_request", "message" => message}} =
               json_response(conn, 422)

      assert message =~ "amount_minor"
    end
  end

  describe "POST /v1/postings" do
    test "posts an arbitrary balanced set of entries", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      fees = Fixtures.account(%{kind: "house"})

      conn =
        post(conn, ~p"/v1/postings", %{
          "idempotency_key" => Fixtures.key(),
          "kind" => "fee",
          "entries" => [
            %{"account_id" => source.id, "amount_minor" => -1_050},
            %{"account_id" => destination.id, "amount_minor" => 1_000},
            %{"account_id" => fees.id, "amount_minor" => 50}
          ]
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["kind"] == "fee"
      assert length(data["entries"]) == 3
    end

    test "entries that do not sum to zero are 422 unbalanced", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      conn =
        post(conn, ~p"/v1/postings", %{
          "idempotency_key" => Fixtures.key(),
          "entries" => [
            %{"account_id" => source.id, "amount_minor" => -100},
            %{"account_id" => destination.id, "amount_minor" => 99}
          ]
        })

      assert %{"error" => %{"code" => "unbalanced"}} = json_response(conn, 422)
    end
  end

  describe "GET /v1/transactions/:id" do
    test "returns a transaction and its entries", %{
      conn: conn,
      source: source,
      destination: destination
    } do
      created =
        post(conn, ~p"/v1/transfers", %{
          "idempotency_key" => Fixtures.key(),
          "from" => source.id,
          "to" => destination.id,
          "amount_minor" => 700
        })

      id = json_response(created, 201)["data"]["id"]

      conn = get(conn, ~p"/v1/transactions/#{id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == id
      assert data["outcome"] == "found"
      assert length(data["entries"]) == 2
    end

    test "is 404 for an unknown id", %{conn: conn} do
      conn = get(conn, ~p"/v1/transactions/#{Ecto.UUID.generate()}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end
  end
end
