defmodule Clearing.Ledger.Accounts.Server do
  @moduledoc """
  One process per account: its cached balance, and the lock that serialises
  postings against it.

  ## Why a process rather than `SELECT ... FOR UPDATE`

  Row locks would also work, and would be less code. What the process buys is
  the balance in memory on the hot path -- a posting validates sufficiency
  without a read query -- and one obvious place to put per-account policy
  later. What it costs is this module: a lock manager, and the ordering
  discipline in `Clearing.Ledger.Postings` that keeps it deadlock-free.
  `docs/decisions/0001-why-elixir-and-go.md` argues the trade; this comment
  exists so nobody thinks the trade was free.

  ## How the lock cannot leak

  Two ways a lock is lost forever, and what stops each:

    * the holder crashes -- the server monitors it and releases on `:DOWN`.
    * the caller's `acquire/2` times out, so it never learns it won the lock --
      `acquire/2` catches its own exit and casts `{:abandon, pid}`, which
      releases the grant that arrived too late, or drops the caller from the
      queue if it never arrived.

  Deadlock is prevented one level up: `Postings` sorts account ids before
  acquiring, so every posting takes its locks in the same global order.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Clearing.Ledger.Accounts.Balance
  alias Clearing.Ledger.Repo

  @registry Clearing.Ledger.Accounts.Registry
  @supervisor Clearing.Ledger.Accounts.Supervisor

  @default_acquire_timeout :timer.seconds(5)

  # A Registry entry is removed when the Registry handles the process's :DOWN,
  # which is not the instant the process exits. So a lookup can hand back a pid
  # that has just stopped -- on idle timeout, most often, under exactly the
  # concurrency this service is built for. Every call retries a bounded number
  # of times, starting a fresh process, rather than crashing the caller.
  @max_attempts 3

  @typedoc "What a posting needs to know about an account before it writes."
  @type snapshot :: %{
          account_id: Ecto.UUID.t(),
          currency: String.t(),
          allow_negative: boolean(),
          amount_minor: integer(),
          version: integer()
        }

  # ── lifecycle ───────────────────────────────────────────────────────────

  @doc false
  def start_link(opts) do
    account_id = Keyword.fetch!(opts, :account_id)
    GenServer.start_link(__MODULE__, account_id, name: via(account_id))
  end

  @doc """
  Returns the running process for `account_id`, starting it if needed.

  `{:error, :not_found}` means the account has no balance row, which means it
  does not exist -- accounts and their balances are created together.
  """
  @spec ensure_started(Ecto.UUID.t()) :: {:ok, pid()} | {:error, :not_found | term()}
  def ensure_started(account_id) do
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: start_child(account_id)
      [] -> start_child(account_id)
    end
  end

  defp start_child(account_id) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, account_id: account_id}) do
      {:ok, pid} -> {:ok, pid}
      # Two callers raced to start the same account. Either one may proceed.
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:shutdown, :not_found}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops the process for `account_id`, if one is running."
  @spec stop(Ecto.UUID.t()) :: :ok
  def stop(account_id) do
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> halt(pid, account_id)
      [] -> :ok
    end
  end

  defp halt(pid, account_id) do
    GenServer.stop(pid, :normal)
    await_unregistered(account_id, 200)
  catch
    # It stopped on its own between the lookup and the call. That is the
    # outcome we wanted anyway.
    :exit, _ -> await_unregistered(account_id, 200)
  end

  # `stop/1` that returns while the Registry still points at the dead process
  # is a trap: the very next `ensure_started/1` hands that pid back. Waiting
  # here makes stopping mean stopped.
  defp await_unregistered(_account_id, 0), do: :ok

  defp await_unregistered(account_id, attempts) do
    case Registry.lookup(@registry, account_id) do
      [] ->
        :ok

      _still_there ->
        Process.sleep(1)
        await_unregistered(account_id, attempts - 1)
    end
  end

  # ── the lock ────────────────────────────────────────────────────────────

  @doc """
  Blocks until the calling process holds the lock on `account_id`.

  On timeout the caller may still have been granted the lock a moment later,
  so it tells the server to take it back before returning.
  """
  @spec acquire(Ecto.UUID.t(), timeout()) ::
          :ok | {:error, :not_found | :timeout | :unavailable}
  def acquire(account_id, timeout \\ @default_acquire_timeout) do
    with_server(account_id, fn pid ->
      try do
        GenServer.call(pid, :acquire, timeout)
      catch
        # The caller has stopped waiting, but the server may grant the lock a
        # moment later. Tell it to take the grant back, or to drop us from the
        # queue if it has not granted anything yet.
        :exit, {:timeout, _} ->
          abandon(account_id)
          {:error, :timeout}
      end
    end)
  end

  @doc "Releases the lock held by the calling process."
  @spec release(Ecto.UUID.t()) :: :ok
  def release(account_id), do: cast(account_id, {:release, self()})

  defp abandon(account_id), do: cast(account_id, {:abandon, self()})

  @doc """
  Records a committed change so the cached balance matches the database.

  `version` is the value the balance row now carries, not the delta.
  """
  @spec applied(Ecto.UUID.t(), integer(), integer()) :: :ok
  def applied(account_id, delta, version), do: cast(account_id, {:applied, delta, version})

  @doc "The cached balance and version, without touching the database."
  @spec snapshot(Ecto.UUID.t()) :: {:ok, snapshot()} | {:error, :not_found | :unavailable}
  def snapshot(account_id) do
    with_server(account_id, &GenServer.call(&1, :snapshot))
  end

  # Runs `work` against a live process, restarting and retrying if the one we
  # were handed had already stopped. Bounded, so a genuinely broken account
  # fails instead of spinning.
  defp with_server(account_id, work, attempt \\ 1) do
    with {:ok, pid} <- ensure_started(account_id) do
      work.(pid)
    end
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      retry(account_id, work, attempt)
  end

  defp retry(_account_id, _work, attempt) when attempt >= @max_attempts,
    do: {:error, :unavailable}

  defp retry(account_id, work, attempt) do
    Process.sleep(1)
    with_server(account_id, work, attempt + 1)
  end

  defp cast(account_id, message) do
    case Registry.lookup(@registry, account_id) do
      [{pid, _}] -> GenServer.cast(pid, message)
      [] -> :ok
    end

    :ok
  end

  defp via(account_id), do: {:via, Registry, {@registry, account_id}}

  # ── server ──────────────────────────────────────────────────────────────

  @impl GenServer
  def init(account_id) do
    case Repo.get(Balance, account_id) do
      nil ->
        # Not an error worth a crash report: asking about an account that does
        # not exist is an ordinary 404 one layer up.
        {:stop, {:shutdown, :not_found}}

      balance ->
        {:ok, fresh(account_id, balance), idle_timeout()}
    end
  end

  defp fresh(account_id, balance) do
    %{
      account_id: account_id,
      currency: balance.currency,
      allow_negative: balance.allow_negative,
      amount_minor: balance.amount_minor,
      version: balance.version,
      holder: nil,
      waiting: :queue.new()
    }
  end

  @impl GenServer
  def handle_call(:acquire, {pid, _tag}, %{holder: nil} = state) do
    {:reply, :ok, grant(state, pid), :infinity}
  end

  def handle_call(:acquire, from, state) do
    {:noreply, %{state | waiting: :queue.in(from, state.waiting)}, :infinity}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = Map.take(state, [:account_id, :currency, :allow_negative, :amount_minor, :version])
    reply({:ok, snapshot}, state)
  end

  @impl GenServer
  def handle_cast({:release, pid}, %{holder: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    noreply(hand_over(%{state | holder: nil}))
  end

  # A release from something that does not hold the lock is a bug upstream,
  # but taking the lock away from whoever legitimately holds it would turn
  # that bug into corrupted money. Ignore it and say so.
  def handle_cast({:release, pid}, state) do
    Logger.warning("release from non-holder",
      account_id: state.account_id,
      from: inspect(pid)
    )

    noreply(state)
  end

  def handle_cast({:abandon, pid}, %{holder: {pid, _ref}} = state) do
    handle_cast({:release, pid}, state)
  end

  def handle_cast({:abandon, pid}, state) do
    remaining = :queue.filter(fn {waiter, _tag} -> waiter != pid end, state.waiting)
    noreply(%{state | waiting: remaining})
  end

  def handle_cast({:applied, delta, version}, state) do
    noreply(%{state | amount_minor: state.amount_minor + delta, version: version})
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _down_pid, _reason}, %{holder: {_held_by, ref}} = state) do
    # The holder died mid-posting. Its database transaction died with it, so
    # the balance in memory is still correct; only the lock needs freeing.
    noreply(hand_over(%{state | holder: nil}))
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    remaining = :queue.filter(fn {waiter, _tag} -> waiter != pid end, state.waiting)
    noreply(%{state | waiting: remaining})
  end

  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp grant(state, pid), do: %{state | holder: {pid, Process.monitor(pid)}}

  defp hand_over(state) do
    case :queue.out(state.waiting) do
      {{:value, {pid, _tag} = from}, rest} ->
        GenServer.reply(from, :ok)
        %{grant(state, pid) | waiting: rest}

      {:empty, _} ->
        state
    end
  end

  # An idle account gives its memory back. A busy one keeps its balance hot,
  # and a locked one is never idle by definition.
  defp reply(response, state), do: {:reply, response, state, next_timeout(state)}
  defp noreply(state), do: {:noreply, state, next_timeout(state)}

  defp next_timeout(%{holder: nil, waiting: waiting}) do
    if :queue.is_empty(waiting), do: idle_timeout(), else: :infinity
  end

  defp next_timeout(_state), do: :infinity

  defp idle_timeout do
    Application.get_env(:clearing_ledger, :account_idle_timeout_ms, 60_000)
  end
end
