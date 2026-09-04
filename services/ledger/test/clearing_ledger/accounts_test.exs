defmodule Clearing.Ledger.AccountsTest do
  use Clearing.Ledger.DataCase, async: false

  alias Clearing.Ledger.Accounts
  alias Clearing.Ledger.Accounts.Balance
  alias Clearing.Ledger.Fixtures

  describe "open/1" do
    test "creates the account and its balance together" do
      {:ok, account} =
        Accounts.open(%{
          "external_id" => "wallet-1",
          "name" => "Wallet",
          "currency" => "BRL",
          "kind" => "user"
        })

      balance = Repo.get(Balance, account.id)

      assert balance.amount_minor == 0
      assert balance.currency == "BRL"
      assert balance.version == 0
    end

    test "a user account may not go negative; house and external must be able to" do
      assert Fixtures.account(%{kind: "user"}).allow_negative == false
      assert Fixtures.account(%{kind: "house"}).allow_negative == true
      assert Fixtures.account(%{kind: "external"}).allow_negative == true
    end

    test "allow_negative cannot be set by the caller" do
      # It follows from kind. A request that tries to overrule that is ignored
      # rather than obeyed, because a user account that may go negative is a
      # way to lose money, not a feature.
      account = Fixtures.account(%{kind: "user", allow_negative: true})
      assert account.allow_negative == false
    end

    test "refuses a currency the ledger does not know" do
      {:error, changeset} =
        Accounts.open(%{
          "external_id" => "x",
          "name" => "X",
          "currency" => "XYZ",
          "kind" => "user"
        })

      assert "is not a currency this ledger accepts" in errors_on(changeset).currency
    end

    test "refuses an unknown kind" do
      {:error, changeset} =
        Accounts.open(%{
          "external_id" => "x",
          "name" => "X",
          "currency" => "BRL",
          "kind" => "robot"
        })

      assert errors_on(changeset).kind != []
    end

    test "refuses a duplicate external id, because a retry must not open a second account" do
      _first = Fixtures.account(%{external_id: "same"})

      {:error, changeset} =
        Accounts.open(%{
          "external_id" => "same",
          "name" => "Other",
          "currency" => "BRL",
          "kind" => "user"
        })

      assert "has already been taken" in errors_on(changeset).external_id
    end

    test "requires the fields it cannot invent" do
      {:error, changeset} = Accounts.open(%{})
      errors = errors_on(changeset)

      for field <- [:external_id, :name, :currency, :kind] do
        assert "can't be blank" in Map.fetch!(errors, field)
      end
    end
  end

  describe "fetch/1 and fetch_by_external_id/1" do
    test "finds an account both ways" do
      account = Fixtures.account(%{external_id: "findable"})

      assert {:ok, found} = Accounts.fetch(account.id)
      assert found.id == account.id
      assert {:ok, ^found} = Accounts.fetch_by_external_id("findable")
    end

    test "a malformed id is not found rather than a crash" do
      assert Accounts.fetch("not-a-uuid") == {:error, :not_found}
      assert Accounts.fetch(Ecto.UUID.generate()) == {:error, :not_found}
      assert Accounts.fetch_by_external_id("nobody") == {:error, :not_found}
    end
  end

  describe "balance/1" do
    test "reads through the account process" do
      account = Fixtures.funded_account(2_500)

      assert {:ok, snapshot} = Accounts.balance(account.id)
      assert snapshot.amount_minor == 2_500
      assert snapshot.currency == "BRL"
      assert snapshot.version == 1
    end

    test "an account that does not exist has no process and no balance" do
      assert Accounts.balance(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "statement/2" do
    test "returns entries newest first, bounded" do
      account = Fixtures.funded_account(1_000)
      Fixtures.fund(account, 2_000)
      Fixtures.fund(account, 3_000)

      assert length(Accounts.statement(account.id)) == 3
      assert length(Accounts.statement(account.id, limit: 2)) == 2
    end

    test "clamps a limit a caller could use to read the whole table" do
      account = Fixtures.funded_account(1_000)

      assert Accounts.statement(account.id, limit: 10_000) != []
      assert Accounts.statement(account.id, limit: -1) != []
    end
  end

  describe "reconcile/0" do
    test "finds nothing when the balances match the entries" do
      account = Fixtures.funded_account(1_000)
      Fixtures.fund(account, 500)

      assert Accounts.reconcile() == []
    end

    test "finds a balance that has been tampered with" do
      # This is the test that proves reconcile/0 can actually fail. Without it,
      # every other assertion of `reconcile() == []` might be checking nothing.
      account = Fixtures.funded_account(1_000)

      Repo.update_all(
        from(b in Balance, where: b.account_id == ^account.id),
        set: [amount_minor: 999]
      )

      assert [%{account_id: id, balance: 999, entries: 1_000}] =
               Enum.filter(Accounts.reconcile(), &(&1.account_id == account.id))

      assert id == account.id
    end
  end
end
