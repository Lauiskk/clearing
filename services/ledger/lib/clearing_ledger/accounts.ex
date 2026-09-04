defmodule Clearing.Ledger.Accounts do
  @moduledoc """
  Opening accounts, reading balances, and proving the balances are right.
  """

  import Ecto.Query

  alias Clearing.Ledger.Accounts.Account
  alias Clearing.Ledger.Accounts.Balance
  alias Clearing.Ledger.Accounts.Server
  alias Clearing.Ledger.Postings.Entry
  alias Clearing.Ledger.Repo

  @doc """
  Opens an account and its balance row in one transaction.

  The two are created together and never apart: a balance-less account would
  make `Server.init/1` treat a real account as missing, and an account-less
  balance cannot exist because of the foreign key.
  """
  @spec open(map()) :: {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
  def open(attrs) do
    changeset = Account.changeset(%Account{}, attrs)

    Repo.transaction(fn ->
      with {:ok, account} <- Repo.insert(changeset),
           {:ok, _balance} <- Repo.insert(balance_for(account)) do
        account
      else
        {:error, failed} -> Repo.rollback(failed)
      end
    end)
  end

  defp balance_for(account) do
    %Balance{
      account_id: account.id,
      amount_minor: 0,
      currency: account.currency,
      allow_negative: account.allow_negative,
      version: 0,
      updated_at: DateTime.utc_now(:second)
    }
  end

  @doc "Fetches an account by its UUID."
  @spec fetch(Ecto.UUID.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def fetch(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found(Repo.get(Account, uuid))
      :error -> {:error, :not_found}
    end
  end

  @doc "Fetches an account by the identifier its owner knows it as."
  @spec fetch_by_external_id(String.t()) :: {:ok, Account.t()} | {:error, :not_found}
  def fetch_by_external_id(external_id) when is_binary(external_id) do
    found(Repo.get_by(Account, external_id: external_id))
  end

  defp found(nil), do: {:error, :not_found}
  defp found(account), do: {:ok, account}

  @doc """
  The current balance, read from the account's process rather than the database.

  This is the read path a caller hits after posting, and it is the one place
  the in-memory cache is user-visible -- so it is also where a divergence would
  show up first. `reconcile/0` is the test that it cannot.
  """
  @spec balance(Ecto.UUID.t()) :: {:ok, Server.snapshot()} | {:error, :not_found}
  def balance(account_id), do: Server.snapshot(account_id)

  @doc """
  The most recent entries against an account, newest first.
  """
  @spec statement(Ecto.UUID.t(), keyword()) :: [Entry.t()]
  def statement(account_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> min(500) |> max(1)

    Entry
    |> where([e], e.account_id == ^account_id)
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Every account whose cached balance disagrees with the sum of its entries.

  Entries are the truth. An empty list is the only acceptable answer, and the
  reconciliation test asserts exactly that after arbitrary concurrent load --
  which is what makes the cache safe to read from.
  """
  @spec reconcile() :: [%{account_id: Ecto.UUID.t(), balance: integer(), entries: integer()}]
  def reconcile do
    # Two Postgres facts are load-bearing here. A subquery has to select a map
    # or a source, not a tuple. And SUM() over bigint returns *numeric*, which
    # Ecto hands back as a Decimal -- so a caller comparing the result to an
    # integer would find a mismatch that is not there. Cast it back.
    sums =
      from(e in Entry,
        group_by: e.account_id,
        select: %{account_id: e.account_id, total: type(sum(e.amount_minor), :integer)}
      )

    from(b in Balance,
      left_join: s in subquery(sums),
      on: s.account_id == b.account_id,
      where: b.amount_minor != coalesce(s.total, 0),
      select: %{
        account_id: b.account_id,
        balance: b.amount_minor,
        entries: coalesce(s.total, 0)
      }
    )
    |> Repo.all()
  end
end
