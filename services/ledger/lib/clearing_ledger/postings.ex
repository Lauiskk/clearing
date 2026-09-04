defmodule Clearing.Ledger.Postings do
  @moduledoc """
  Posting money: validate, take the locks in a fixed order, write, and tell the
  account processes what happened.

  ## The order of things, and why

  1. **Validate against the accounts**, not against the request. The caller
     sends account ids and amounts; the currency of each entry comes from the
     account it lands on, so a request cannot name a currency the account does
     not hold. That removes an entire class of bug at the boundary rather than
     catching it at COMMIT.

  2. **Check for a replay before taking any lock.** A retry is the common case
     under a flaky network, and it should be a single indexed read.

  3. **Sort the account ids, then acquire.** Every posting in the system takes
     its locks in the same global order, so two postings touching the same two
     accounts can never each hold what the other wants. This one line is the
     whole deadlock-freedom argument.

  4. **Commit, then update the caches.** If the process dies between the two,
     the database is still right and the next `Server.init/1` reloads from it.
     The reverse order would leave a cache claiming money that was never
     written.
  """

  import Ecto.Query

  alias Clearing.Ledger.Accounts.Account
  alias Clearing.Ledger.Accounts.Balance
  alias Clearing.Ledger.Accounts.Server
  alias Clearing.Ledger.Money
  alias Clearing.Ledger.Postings.Entry
  alias Clearing.Ledger.Postings.Transaction
  alias Clearing.Ledger.Repo

  @lock_timeout :timer.seconds(5)

  @typedoc """
  Why a posting was refused. Every value here maps to one stable error code at
  the HTTP boundary, so a client can branch on it.
  """
  @type refusal ::
          {:invalid, atom(), String.t()}
          | {:unknown_account, String.t()}
          | {:insufficient_funds, Ecto.UUID.t()}
          | :unbalanced
          | :idempotency_conflict
          | :busy

  @doc """
  Posts a balanced set of entries.

  Returns `{:ok, transaction, :posted}` for new work and
  `{:ok, transaction, :replayed}` when this idempotency key has already been
  used with the same request. Reusing a key with a *different* request is
  `{:error, :idempotency_conflict}`, never a silent replay.
  """
  @spec post(map()) :: {:ok, Transaction.t(), :posted | :replayed} | {:error, refusal()}
  def post(params) do
    with {:ok, plan} <- plan(params) do
      case replay(plan) do
        {:ok, transaction} -> {:ok, transaction, :replayed}
        {:error, :digest_mismatch} -> {:error, :idempotency_conflict}
        :none -> execute(plan)
      end
    end
  end

  @doc """
  Moves `amount_minor` from one account to another.

  A thin shell over `post/1`: a transfer is two entries that sum to zero, and
  expressing it that way means it goes through exactly the same validation,
  locking and idempotency as everything else.
  """
  @spec transfer(map()) :: {:ok, Transaction.t(), :posted | :replayed} | {:error, refusal()}
  def transfer(params) do
    with {:ok, from} <- require_param(params, "from", :from),
         {:ok, to} <- require_param(params, "to", :to),
         {:ok, amount} <- positive_amount(params) do
      params
      |> Map.drop(["from", "to", "amount_minor"])
      |> Map.put("kind", Map.get(params, "kind", "transfer"))
      |> Map.put("entries", [
        %{"account_id" => from, "amount_minor" => -amount},
        %{"account_id" => to, "amount_minor" => amount}
      ])
      |> post()
    end
  end

  # The field name is passed in as an atom rather than derived from the key
  # with String.to_atom/1. The keys here are literals, so deriving them would
  # be safe today -- and would be an unbounded atom table the day someone
  # makes the key dynamic. Atoms are never garbage collected.
  defp require_param(params, key, field) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid, field, "is required"}}
    end
  end

  defp positive_amount(params) do
    case Money.cast(Map.get(params, "amount_minor")) do
      {:ok, amount} when amount > 0 -> {:ok, amount}
      {:ok, _} -> {:error, {:invalid, :amount_minor, "must be greater than zero"}}
      {:error, :not_an_integer} -> {:error, {:invalid, :amount_minor, "must be an integer"}}
      {:error, :out_of_range} -> {:error, {:invalid, :amount_minor, "is out of range"}}
    end
  end

  @doc "Fetches a transaction and its entries."
  @spec fetch(Ecto.UUID.t()) :: {:ok, Transaction.t()} | {:error, :not_found}
  def fetch(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found(Repo.get(Transaction, uuid) |> preload_entries())
      :error -> {:error, :not_found}
    end
  end

  defp preload_entries(nil), do: nil
  defp preload_entries(transaction), do: Repo.preload(transaction, :entries)

  defp found(nil), do: {:error, :not_found}
  defp found(transaction), do: {:ok, transaction}

  # ── planning ────────────────────────────────────────────────────────────

  defp plan(params) do
    with {:ok, key} <- idempotency_key(params),
         {:ok, kind} <- kind(params),
         {:ok, reference} <- reference(params),
         {:ok, requested} <- requested_entries(params),
         {:ok, accounts} <- load_accounts(requested),
         {:ok, entries} <- resolve(requested, accounts),
         :ok <- balanced?(entries) do
      {:ok,
       %{
         idempotency_key: key,
         kind: kind,
         reference: reference,
         digest: digest(kind, reference, entries),
         entries: entries,
         deltas: deltas(entries),
         accounts: accounts
       }}
    end
  end

  defp idempotency_key(params) do
    case Map.get(params, "idempotency_key") do
      key when is_binary(key) and byte_size(key) >= 8 and byte_size(key) <= 255 -> {:ok, key}
      _ -> {:error, {:invalid, :idempotency_key, "must be a string of 8 to 255 characters"}}
    end
  end

  defp kind(params) do
    kind = Map.get(params, "kind", "transfer")

    if kind in Transaction.kinds(),
      do: {:ok, kind},
      else: {:error, {:invalid, :kind, "must be one of #{Enum.join(Transaction.kinds(), ", ")}"}}
  end

  defp reference(params) do
    case Map.get(params, "reference") do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= 255 -> {:ok, value}
      _ -> {:error, {:invalid, :reference, "must be a string of at most 255 characters"}}
    end
  end

  defp requested_entries(params) do
    case Map.get(params, "entries") do
      entries when is_list(entries) and length(entries) >= 2 -> cast_entries(entries)
      _ -> {:error, {:invalid, :entries, "must be a list of at least two entries"}}
    end
  end

  defp cast_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case cast_entry(entry) do
        {:ok, cast} -> {:cont, {:ok, [cast | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp cast_entry(%{"account_id" => id, "amount_minor" => amount}) when is_binary(id) do
    case Money.cast(amount) do
      {:ok, 0} -> {:error, {:invalid, :amount_minor, "must not be zero"}}
      {:ok, cast} -> {:ok, %{account_id: id, amount_minor: cast}}
      {:error, :not_an_integer} -> {:error, {:invalid, :amount_minor, "must be an integer"}}
      {:error, :out_of_range} -> {:error, {:invalid, :amount_minor, "is out of range"}}
    end
  end

  defp cast_entry(_),
    do: {:error, {:invalid, :entries, "each entry needs account_id and amount_minor"}}

  defp load_accounts(requested) do
    ids = requested |> Enum.map(& &1.account_id) |> Enum.uniq()

    case Enum.split_with(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))) do
      {valid, []} -> fetch_accounts(valid, ids)
      {_, [malformed | _]} -> {:error, {:unknown_account, malformed}}
    end
  end

  defp fetch_accounts(valid, requested_ids) do
    accounts =
      Account
      |> where([a], a.id in ^valid)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    case Enum.find(requested_ids, &(not Map.has_key?(accounts, &1))) do
      nil -> {:ok, accounts}
      missing -> {:error, {:unknown_account, missing}}
    end
  end

  # The currency is taken from the account, never from the request. A caller
  # cannot name a currency an account does not hold, because it never names one.
  defp resolve(requested, accounts) do
    {:ok,
     Enum.map(requested, fn entry ->
       account = Map.fetch!(accounts, entry.account_id)
       Map.put(entry, :currency, account.currency)
     end)}
  end

  defp balanced?(entries) do
    entries
    |> Enum.group_by(& &1.currency, & &1.amount_minor)
    |> Enum.all?(fn {_currency, amounts} -> Enum.sum(amounts) == 0 end)
    |> if(do: :ok, else: {:error, :unbalanced})
  end

  defp deltas(entries) do
    entries
    |> Enum.group_by(& &1.account_id, & &1.amount_minor)
    |> Map.new(fn {account_id, amounts} -> {account_id, Enum.sum(amounts)} end)
  end

  # A stable fingerprint of what the request *means*, so JSON key order and
  # whitespace cannot make the same request look like a different one.
  defp digest(kind, reference, entries) do
    entries
    |> Enum.map(&"#{&1.account_id}:#{&1.amount_minor}:#{&1.currency}")
    |> Enum.sort()
    |> then(&:crypto.hash(:sha256, Enum.join([kind, reference || "" | &1], "\n")))
  end

  # ── idempotency ─────────────────────────────────────────────────────────

  defp replay(plan) do
    case Repo.get_by(Transaction, idempotency_key: plan.idempotency_key) do
      nil ->
        :none

      %{request_digest: digest} = transaction when digest == plan.digest ->
        {:ok, preload_entries(transaction)}

      _different ->
        {:error, :digest_mismatch}
    end
  end

  # ── execution ───────────────────────────────────────────────────────────

  defp execute(plan) do
    ordered = plan.deltas |> Map.keys() |> Enum.sort()

    with :ok <- ensure_started(ordered) do
      locked(ordered, [], fn -> attempt(plan, ordered) end)
    end
  end

  defp ensure_started(account_ids) do
    Enum.reduce_while(account_ids, :ok, fn id, :ok ->
      case Server.ensure_started(id) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, :not_found} -> {:halt, {:error, {:unknown_account, id}}}
        {:error, _reason} -> {:halt, {:error, :busy}}
      end
    end)
  end

  # Sorted acquisition. `held` accumulates in reverse, which is the order the
  # locks are given back in.
  defp locked([], held, work) do
    work.()
  after
    Enum.each(held, &Server.release/1)
  end

  defp locked([id | rest], held, work) do
    case Server.acquire(id, @lock_timeout) do
      :ok ->
        locked(rest, [id | held], work)

      {:error, reason} ->
        Enum.each(held, &Server.release/1)
        {:error, if(reason == :not_found, do: {:unknown_account, id}, else: :busy)}
    end
  end

  defp attempt(plan, account_ids) do
    with {:ok, snapshots} <- snapshots(account_ids),
         :ok <- sufficient?(plan, snapshots),
         {:ok, transaction, outcome} <- commit(plan, snapshots) do
      # Only a posting that actually wrote may move the cached balances. Losing
      # the race on an idempotency key means our transaction rolled back and
      # somebody else's identical one is already reflected in the cache.
      if outcome == :posted, do: announce(plan, snapshots)
      {:ok, transaction, outcome}
    end
  end

  defp snapshots(account_ids) do
    Enum.reduce_while(account_ids, {:ok, %{}}, fn id, {:ok, acc} ->
      case Server.snapshot(id) do
        {:ok, snapshot} -> {:cont, {:ok, Map.put(acc, id, snapshot)}}
        {:error, :not_found} -> {:halt, {:error, {:unknown_account, id}}}
      end
    end)
  end

  defp sufficient?(plan, snapshots) do
    plan.deltas
    |> Enum.find(fn {id, delta} -> overdrawn?(Map.fetch!(snapshots, id), delta) end)
    |> case do
      nil -> :ok
      {id, _delta} -> {:error, {:insufficient_funds, id}}
    end
  end

  defp overdrawn?(%{allow_negative: true}, _delta), do: false
  defp overdrawn?(snapshot, delta), do: snapshot.amount_minor + delta < 0

  defp commit(plan, snapshots) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      with {:ok, transaction} <- insert_transaction(plan),
           rows = entry_rows(plan, transaction, now),
           :ok <- insert_entries(rows, length(plan.entries)),
           :ok <- move_balances(plan, snapshots, now) do
        # The rows that were written, not a second set generated from the same
        # plan -- regenerating them would hand the caller entry ids that are
        # nowhere in the database.
        %{transaction | entries: Enum.map(rows, &struct(Entry, &1))}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, transaction} -> {:ok, transaction, :posted}
      # Another request won the race on this key. It wrote the same thing --
      # the digest is checked before we get here -- so this is a replay.
      {:error, :duplicate_key} -> replay_after_race(plan)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_transaction(plan) do
    attrs = %{
      idempotency_key: plan.idempotency_key,
      kind: plan.kind,
      reference: plan.reference,
      request_digest: plan.digest
    }

    %Transaction{}
    |> Transaction.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, transaction} -> {:ok, transaction}
      {:error, changeset} -> {:error, insert_failure(changeset)}
    end
  end

  defp insert_failure(changeset) do
    if Keyword.has_key?(changeset.errors, :idempotency_key),
      do: :duplicate_key,
      else: {:invalid, :transaction, render_first_error(changeset)}
  end

  defp render_first_error(%{errors: [{field, {message, _opts}} | _]}), do: "#{field} #{message}"
  defp render_first_error(_), do: "is invalid"

  defp insert_entries(rows, expected) do
    {count, _} = Repo.insert_all(Entry, rows)
    if count == expected, do: :ok, else: {:error, :entries_not_written}
  end

  defp entry_rows(plan, transaction, now) do
    Enum.map(plan.entries, fn entry ->
      %{
        id: Ecto.UUID.generate(),
        transaction_id: transaction.id,
        account_id: entry.account_id,
        amount_minor: entry.amount_minor,
        currency: entry.currency,
        inserted_at: now
      }
    end)
  end

  defp move_balances(plan, snapshots, now) do
    Enum.reduce_while(plan.deltas, :ok, fn {id, delta}, :ok ->
      case move_balance(id, delta, Map.fetch!(snapshots, id).version, now) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp move_balance(account_id, delta, version, now) do
    {count, _} =
      Balance
      |> where([b], b.account_id == ^account_id and b.version == ^version)
      |> Repo.update_all(inc: [amount_minor: delta, version: 1], set: [updated_at: now])

    # Zero rows means the version moved under a held lock, which should be
    # impossible. Failing here is the whole reason the column exists.
    if count == 1, do: :ok, else: {:error, {:stale_balance, account_id}}
  end

  defp announce(plan, snapshots) do
    Enum.each(plan.deltas, fn {id, delta} ->
      Server.applied(id, delta, Map.fetch!(snapshots, id).version + 1)
    end)
  end

  defp replay_after_race(plan) do
    case replay(plan) do
      {:ok, transaction} -> {:ok, transaction, :replayed}
      {:error, :digest_mismatch} -> {:error, :idempotency_conflict}
      :none -> {:error, :busy}
    end
  end
end
