defmodule Clearing.Ledger.Accounts.ServerTest do
  @moduledoc """
  The lock manager on its own, away from any money.

  Everything here is a way the lock could be lost or double-granted. Each one
  corresponds to a defence in `Clearing.Ledger.Accounts.Server`, and each test
  fails if that defence is removed.
  """

  use Clearing.Ledger.DataCase, async: false

  import ExUnit.CaptureLog

  alias Clearing.Ledger.Accounts.Server
  alias Clearing.Ledger.Fixtures

  describe "ensure_started/1" do
    test "starts once and then returns the same process" do
      account = Fixtures.account()

      assert {:ok, pid} = Server.ensure_started(account.id)
      assert {:ok, ^pid} = Server.ensure_started(account.id)
      assert Process.alive?(pid)
    end

    test "an account with no balance row has no process" do
      assert Server.ensure_started(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "loads the stored balance on start" do
      account = Fixtures.funded_account(4_200)
      Server.stop(account.id)

      assert {:ok, snapshot} = Server.snapshot(account.id)
      assert snapshot.amount_minor == 4_200
      assert snapshot.currency == "BRL"
      assert snapshot.allow_negative == false
    end
  end

  describe "the lock" do
    setup do
      %{account: Fixtures.account()}
    end

    test "is granted immediately when free", %{account: account} do
      assert Server.acquire(account.id) == :ok
      assert Server.release(account.id) == :ok
    end

    test "makes the second caller wait, then hands over on release", %{account: account} do
      test_pid = self()

      other =
        spawn(fn ->
          :ok = Server.acquire(account.id)
          send(test_pid, :other_holds)
          receive do: (:done -> Server.release(account.id))
        end)

      assert_receive :other_holds, 5_000

      waiter = Task.async(fn -> Server.acquire(account.id, 5_000) end)

      # Still held by `other`, so the waiter has not been granted anything.
      refute Task.yield(waiter, 200)

      send(other, :done)
      assert Task.await(waiter, 5_000) == :ok
    end

    test "is released when the holder dies", %{account: account} do
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = Server.acquire(account.id)
          send(test_pid, :held)
          Process.sleep(:infinity)
        end)

      assert_receive :held, 5_000
      Process.exit(holder, :kill)

      # The monitor, not a timeout, is what makes this fast.
      assert Server.acquire(account.id, 2_000) == :ok
    end

    test "is not taken away by a release from somebody else", %{account: account} do
      assert Server.acquire(account.id) == :ok

      # A stray release must not hand the lock to the next waiter while the
      # real holder is still using it. The server logs the attempt; capturing
      # it keeps the expected warning out of the suite's output.
      capture_log(fn ->
        Task.await(Task.async(fn -> Server.release(account.id) end))
        # Give the cast time to be handled before we assert on its effect.
        Process.sleep(50)
      end)

      waiter = Task.async(fn -> Server.acquire(account.id, 3_000) end)
      refute Task.yield(waiter, 300)

      Server.release(account.id)
      assert Task.await(waiter, 5_000) == :ok
    end

    test "is not leaked when the caller times out waiting", %{account: account} do
      test_pid = self()

      holder =
        spawn(fn ->
          :ok = Server.acquire(account.id)
          send(test_pid, :held)
          receive do: (:release -> Server.release(account.id))
        end)

      assert_receive :held, 5_000

      # This caller gives up. The grant that arrives a moment later must not
      # sit there held by a process that has stopped waiting for it.
      assert Server.acquire(account.id, 100) == {:error, :timeout}

      send(holder, :release)

      assert Server.acquire(account.id, 2_000) == :ok
    end
  end

  describe "snapshot/1 and applied/3" do
    test "reflect a committed change without a database read" do
      account = Fixtures.account()
      {:ok, before} = Server.snapshot(account.id)

      assert before.amount_minor == 0
      assert before.version == 0

      Server.applied(account.id, 750, 1)

      assert {:ok, %{amount_minor: 750, version: 1}} = Server.snapshot(account.id)
    end

    test "a missing account has no snapshot" do
      assert Server.snapshot(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "idle accounts" do
    test "stop, and reload their balance when next needed" do
      previous = Application.get_env(:clearing_ledger, :account_idle_timeout_ms)
      Application.put_env(:clearing_ledger, :account_idle_timeout_ms, 50)
      on_exit(fn -> Application.put_env(:clearing_ledger, :account_idle_timeout_ms, previous) end)

      account = Fixtures.funded_account(1_500)
      Server.stop(account.id)

      {:ok, pid} = Server.ensure_started(account.id)
      reference = Process.monitor(pid)

      assert_receive {:DOWN, ^reference, :process, ^pid, :normal}, 2_000

      # Restarting reads the balance back out of the database, so nothing was
      # lost by letting the process go.
      assert {:ok, %{amount_minor: 1_500}} = Server.snapshot(account.id)
    end

    test "do not stop while the lock is held" do
      previous = Application.get_env(:clearing_ledger, :account_idle_timeout_ms)
      Application.put_env(:clearing_ledger, :account_idle_timeout_ms, 50)
      on_exit(fn -> Application.put_env(:clearing_ledger, :account_idle_timeout_ms, previous) end)

      account = Fixtures.account()
      {:ok, pid} = Server.ensure_started(account.id)
      assert Server.acquire(account.id) == :ok

      reference = Process.monitor(pid)
      refute_receive {:DOWN, ^reference, :process, ^pid, _}, 300

      Server.release(account.id)
    end
  end

  describe "stop/1" do
    test "is safe when there is nothing to stop" do
      assert Server.stop(Ecto.UUID.generate()) == :ok
    end
  end
end
