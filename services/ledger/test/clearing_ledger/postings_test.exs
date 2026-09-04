defmodule Clearing.Ledger.PostingsTest do
  @moduledoc """
  What these tests do and do not prove.

  They run against a real Postgres through `Ecto.Adapters.SQL.Sandbox` in
  shared mode, which means every process in a test shares one connection. So
  the concurrency here is real at the *process* level -- N tasks genuinely race
  for the account locks -- but the database work behind those locks is
  serialised by the sandbox. Postgres' own isolation is not what is under test;
  the lock manager and the arithmetic are.
  """

  use Clearing.Ledger.DataCase, async: false
  use ExUnitProperties

  alias Clearing.Ledger.Accounts
  alias Clearing.Ledger.Accounts.Balance
  alias Clearing.Ledger.Accounts.Server
  alias Clearing.Ledger.Fixtures
  alias Clearing.Ledger.Postings
  alias Clearing.Ledger.Postings.Entry

  describe "transfer/1" do
    test "moves money and leaves both balances exact" do
      source = Fixtures.funded_account(10_000)
      destination = Fixtures.account()

      assert {:ok, transaction, :posted} =
               Postings.transfer(%{
                 "idempotency_key" => Fixtures.key(),
                 "from" => source.id,
                 "to" => destination.id,
                 "amount_minor" => 2_500,
                 "reference" => "invoice-42"
               })

      assert transaction.kind == "transfer"
      assert transaction.reference == "invoice-42"
      assert length(transaction.entries) == 2

      assert {:ok, %{amount_minor: 7_500}} = Accounts.balance(source.id)
      assert {:ok, %{amount_minor: 2_500}} = Accounts.balance(destination.id)
      assert Accounts.reconcile() == []
    end

    test "the entries it returns are the entries that were stored" do
      source = Fixtures.funded_account(1_000)
      destination = Fixtures.account()

      {:ok, transaction, :posted} =
        Postings.transfer(%{
          "idempotency_key" => Fixtures.key(),
          "from" => source.id,
          "to" => destination.id,
          "amount_minor" => 400
        })

      stored = Repo.all(from(e in Entry, where: e.transaction_id == ^transaction.id))

      assert Enum.map(transaction.entries, & &1.id) |> Enum.sort() ==
               Enum.map(stored, & &1.id) |> Enum.sort()
    end

    test "refuses to overdraw a user account" do
      source = Fixtures.funded_account(1_000)
      destination = Fixtures.account()

      assert {:error, {:insufficient_funds, id}} =
               Postings.transfer(%{
                 "idempotency_key" => Fixtures.key(),
                 "from" => source.id,
                 "to" => destination.id,
                 "amount_minor" => 1_001
               })

      assert id == source.id
      assert {:ok, %{amount_minor: 1_000}} = Accounts.balance(source.id)
    end

    test "lets a house account go negative, because that is what house accounts are for" do
      house = Fixtures.account(%{kind: "house"})
      customer = Fixtures.account()

      assert {:ok, _transaction, :posted} =
               Postings.transfer(%{
                 "idempotency_key" => Fixtures.key(),
                 "from" => house.id,
                 "to" => customer.id,
                 "amount_minor" => 5_000
               })

      assert {:ok, %{amount_minor: -5_000}} = Accounts.balance(house.id)
    end

    test "validates its own arguments before touching anything" do
      account = Fixtures.account()

      base = %{"idempotency_key" => Fixtures.key(), "from" => account.id, "to" => account.id}

      assert {:error, {:invalid, :from, _}} = Postings.transfer(Map.delete(base, "from"))
      assert {:error, {:invalid, :to, _}} = Postings.transfer(Map.delete(base, "to"))
      assert {:error, {:invalid, :amount_minor, _}} = Postings.transfer(base)

      assert {:error, {:invalid, :amount_minor, _}} =
               Postings.transfer(Map.put(base, "amount_minor", 0))

      assert {:error, {:invalid, :amount_minor, _}} =
               Postings.transfer(Map.put(base, "amount_minor", -5))

      assert {:error, {:invalid, :amount_minor, _}} =
               Postings.transfer(Map.put(base, "amount_minor", 1.5))
    end
  end

  describe "post/1 validation" do
    setup do
      %{account: Fixtures.funded_account(10_000), other: Fixtures.account()}
    end

    test "refuses entries that do not sum to zero", %{account: a, other: b} do
      assert {:error, :unbalanced} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -500},
                   %{"account_id" => b.id, "amount_minor" => 400}
                 ]
               })
    end

    test "requires each currency to balance on its own", %{account: a, other: b} do
      # The debited side must be allowed to go negative, or this test fails for
      # insufficient funds before it ever reaches the balancing rule.
      dollars = Fixtures.account(%{currency: "USD", kind: "house"})
      more_dollars = Fixtures.account(%{currency: "USD"})

      # Each pair balances within itself, so this is accepted...
      assert {:ok, _, :posted} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -500},
                   %{"account_id" => b.id, "amount_minor" => 500},
                   %{"account_id" => dollars.id, "amount_minor" => -700},
                   %{"account_id" => more_dollars.id, "amount_minor" => 700}
                 ]
               })

      # ...but a BRL debit cannot be settled by a USD credit.
      assert {:error, :unbalanced} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -500},
                   %{"account_id" => dollars.id, "amount_minor" => 500}
                 ]
               })
    end

    test "refuses fewer than two entries", %{account: a} do
      assert {:error, {:invalid, :entries, _}} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [%{"account_id" => a.id, "amount_minor" => 0}]
               })

      assert {:error, {:invalid, :entries, _}} =
               Postings.post(%{"idempotency_key" => Fixtures.key(), "entries" => []})

      assert {:error, {:invalid, :entries, _}} =
               Postings.post(%{"idempotency_key" => Fixtures.key()})
    end

    test "refuses an unknown or malformed account", %{account: a} do
      missing = Ecto.UUID.generate()

      assert {:error, {:unknown_account, ^missing}} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -500},
                   %{"account_id" => missing, "amount_minor" => 500}
                 ]
               })

      assert {:error, {:unknown_account, "nope"}} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -500},
                   %{"account_id" => "nope", "amount_minor" => 500}
                 ]
               })
    end

    test "refuses an idempotency key too short to be unique in practice", %{account: a, other: b} do
      assert {:error, {:invalid, :idempotency_key, _}} =
               Postings.post(%{
                 "idempotency_key" => "short",
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -100},
                   %{"account_id" => b.id, "amount_minor" => 100}
                 ]
               })
    end

    test "refuses an unknown transaction kind", %{account: a, other: b} do
      assert {:error, {:invalid, :kind, _}} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "kind" => "laundering",
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => -100},
                   %{"account_id" => b.id, "amount_minor" => 100}
                 ]
               })
    end

    test "an entry may not be zero", %{account: a, other: b} do
      assert {:error, {:invalid, :amount_minor, _}} =
               Postings.post(%{
                 "idempotency_key" => Fixtures.key(),
                 "entries" => [
                   %{"account_id" => a.id, "amount_minor" => 0},
                   %{"account_id" => b.id, "amount_minor" => 0}
                 ]
               })
    end
  end

  describe "idempotency" do
    setup do
      %{source: Fixtures.funded_account(10_000), destination: Fixtures.account()}
    end

    test "the same request twice posts once", %{source: source, destination: destination} do
      request = %{
        "idempotency_key" => Fixtures.key(),
        "from" => source.id,
        "to" => destination.id,
        "amount_minor" => 3_000
      }

      assert {:ok, first, :posted} = Postings.transfer(request)
      assert {:ok, second, :replayed} = Postings.transfer(request)

      assert first.id == second.id
      assert {:ok, %{amount_minor: 7_000}} = Accounts.balance(source.id)
      assert Repo.aggregate(Entry, :count) == 4
    end

    test "a replay returns the stored entries", %{source: source, destination: destination} do
      request = %{
        "idempotency_key" => Fixtures.key(),
        "from" => source.id,
        "to" => destination.id,
        "amount_minor" => 3_000
      }

      {:ok, _, :posted} = Postings.transfer(request)
      {:ok, replayed, :replayed} = Postings.transfer(request)

      assert length(replayed.entries) == 2
      assert Enum.sum(Enum.map(replayed.entries, & &1.amount_minor)) == 0
    end

    test "the same key with a different body is a conflict, not a replay", %{
      source: source,
      destination: destination
    } do
      key = Fixtures.key()

      request = %{
        "idempotency_key" => key,
        "from" => source.id,
        "to" => destination.id,
        "amount_minor" => 3_000
      }

      assert {:ok, _, :posted} = Postings.transfer(request)

      # Silently returning the first result here would post 3000 and report
      # success for a request that asked for 4000.
      assert {:error, :idempotency_conflict} =
               Postings.transfer(%{request | "amount_minor" => 4_000})

      assert {:ok, %{amount_minor: 7_000}} = Accounts.balance(source.id)
    end

    test "key reuse is detected regardless of entry order", %{
      source: source,
      destination: destination
    } do
      key = Fixtures.key()

      forward = [
        %{"account_id" => source.id, "amount_minor" => -1_000},
        %{"account_id" => destination.id, "amount_minor" => 1_000}
      ]

      assert {:ok, first, :posted} =
               Postings.post(%{"idempotency_key" => key, "entries" => forward})

      assert {:ok, second, :replayed} =
               Postings.post(%{"idempotency_key" => key, "entries" => Enum.reverse(forward)})

      assert first.id == second.id
    end
  end

  describe "concurrency" do
    test "fifty concurrent transfers leave an exact balance" do
      source = Fixtures.funded_account(100_000)
      destination = Fixtures.account()

      results = concurrent_transfers(source, destination, 1..50, 1_000)

      assert Enum.count(results, &match?({:ok, _, :posted}, &1)) == 50
      assert {:ok, %{amount_minor: 50_000}} = Accounts.balance(source.id)
      assert {:ok, %{amount_minor: 50_000}} = Accounts.balance(destination.id)
      assert Accounts.reconcile() == []
    end

    test "concurrent transfers cannot overdraw: exactly the funded amount goes out" do
      # Ten thousand available, twenty racing requests for a thousand each.
      # Exactly ten must win. A lost update would let eleven through and leave
      # the balance negative, which the database would then also refuse.
      source = Fixtures.funded_account(10_000)
      destination = Fixtures.account()

      results = concurrent_transfers(source, destination, 1..20, 1_000)

      posted = Enum.count(results, &match?({:ok, _, :posted}, &1))
      refused = Enum.count(results, &match?({:error, {:insufficient_funds, _}}, &1))

      assert posted == 10
      assert refused == 10
      assert {:ok, %{amount_minor: 0}} = Accounts.balance(source.id)
      assert {:ok, %{amount_minor: 10_000}} = Accounts.balance(destination.id)
      assert Accounts.reconcile() == []
    end

    test "the cached balance and the stored balance agree after a race" do
      source = Fixtures.funded_account(20_000)
      destination = Fixtures.account()

      concurrent_transfers(source, destination, 1..20, 500)

      {:ok, cached} = Accounts.balance(source.id)
      stored = Repo.get(Balance, source.id)

      assert cached.amount_minor == stored.amount_minor
      assert cached.version == stored.version
    end

    defp concurrent_transfers(source, destination, range, amount) do
      range
      |> Task.async_stream(
        fn i ->
          Postings.transfer(%{
            "idempotency_key" => "race-#{i}-#{System.unique_integer([:positive])}",
            "from" => source.id,
            "to" => destination.id,
            "amount_minor" => amount
          })
        end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
    end
  end

  describe "a holder that dies" do
    test "releases its lock, and the next posting proceeds" do
      source = Fixtures.funded_account(5_000)
      destination = Fixtures.account()
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = Server.acquire(source.id)
          send(test_pid, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held, 5_000
      Process.exit(holder, :kill)

      # Without the monitor in Server, this transfer would block until the
      # acquire timeout and then fail.
      assert {:ok, _transaction, :posted} =
               Postings.transfer(%{
                 "idempotency_key" => Fixtures.key(),
                 "from" => source.id,
                 "to" => destination.id,
                 "amount_minor" => 1_000
               })
    end
  end

  describe "money is conserved" do
    property "no sequence of transfers creates or destroys money" do
      check all(
              amounts <- list_of(integer(1..5_000), min_length: 1, max_length: 15),
              max_runs: 20
            ) do
        source = Fixtures.funded_account(20_000)
        destination = Fixtures.account()

        # Some of these will be refused for insufficient funds. That is part of
        # the test: whichever subset succeeds, the totals must still hold.
        for amount <- amounts do
          Postings.transfer(%{
            "idempotency_key" => Fixtures.key(),
            "from" => source.id,
            "to" => destination.id,
            "amount_minor" => amount
          })
        end

        # Every account starts at zero and every posting sums to zero, so the
        # sum of every balance in the ledger is zero. Always. If a posting ever
        # created a centavo, this is the assertion that finds it.
        assert sum_of(Balance, :amount_minor) == 0
        assert sum_of(Entry, :amount_minor) == 0
        assert Accounts.reconcile() == []
      end
    end

    defp sum_of(schema, field) do
      case Repo.aggregate(schema, :sum, field) do
        nil -> 0
        %Decimal{} = decimal -> Decimal.to_integer(decimal)
        integer -> integer
      end
    end
  end
end
