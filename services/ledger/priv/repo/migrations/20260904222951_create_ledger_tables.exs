defmodule Clearing.Ledger.Repo.Migrations.CreateLedgerTables do
  use Ecto.Migration

  @moduledoc """
  The four tables a double-entry ledger needs.

  `entries` is the truth: append-only, never updated, never deleted. `balances`
  is a cache of `SUM(entries.amount_minor)` per account, maintained in the same
  transaction as the entries that move it, so a reader never has to aggregate
  the whole history to answer "how much does this account hold". A test
  reconciles the two after arbitrary load; if they ever disagree, the entries
  win and the balance is the thing that is wrong.
  """

  def change do
    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The caller's own identifier. Callers retry, and a retry that creates a
      # second account is worse than one that fails, so this is unique.
      add :external_id, :string, null: false
      add :name, :string, null: false

      # ISO 4217. An account holds exactly one currency: "converting" inside an
      # account would silently destroy the audit trail of the conversion.
      add :currency, :string, size: 3, null: false

      # user     -- a customer balance; may not go negative.
      # house    -- the system's own accounts (settlement, fees, suspense).
      # external -- the far side of money entering or leaving the system.
      #
      # house and external are the accounts that are *supposed* to run
      # negative: that is what it means for the system to owe someone.
      add :kind, :string, null: false
      add :allow_negative, :boolean, null: false, default: false

      timestamps(type: :timestamptz)
    end

    create unique_index(:accounts, [:external_id])

    create constraint(:accounts, :accounts_kind_known,
             check: "kind IN ('user','house','external')"
           )

    create constraint(:accounts, :accounts_currency_format, check: "currency ~ '^[A-Z]{3}$'")

    # A negative balance is a property of what the account is for, not a
    # decision made per posting. Stating it here means no posting path can
    # forget to check.
    create constraint(:accounts, :accounts_negative_only_for_non_user,
             check: "NOT allow_negative OR kind <> 'user'"
           )

    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The whole idempotency story is this column plus its unique index. A
      # replayed request finds the row it already wrote and returns it.
      add :idempotency_key, :string, null: false
      add :kind, :string, null: false
      add :reference, :string

      # SHA-256 of the request that created this transaction. Reusing a key
      # with a *different* body is a caller bug, not a retry, and answering it
      # with the original result would hide the bug and post the wrong money.
      # Storing the digest is what lets the replay path tell the two apart.
      add :request_digest, :binary, null: false

      # A reversal points at what it reverses. Money is never deleted; it is
      # sent back, and both halves stay on the record.
      add :reverses_id, references(:transactions, type: :binary_id, on_delete: :restrict)

      timestamps(type: :timestamptz, updated_at: false)
    end

    create unique_index(:transactions, [:idempotency_key])
    create index(:transactions, [:reverses_id])

    create constraint(:transactions, :transactions_kind_known,
             check: "kind IN ('transfer','deposit','withdrawal','fee','reversal')"
           )

    create table(:entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :transaction_id,
          references(:transactions, type: :binary_id, on_delete: :restrict),
          null: false

      add :account_id, references(:accounts, type: :binary_id, on_delete: :restrict), null: false

      # Signed minor units. Negative is a debit, positive is a credit, and
      # there is no third representation anywhere in this system: no floats, no
      # decimal strings, no "amount plus a direction flag" that two call sites
      # will eventually disagree about.
      add :amount_minor, :bigint, null: false
      add :currency, :string, size: 3, null: false

      timestamps(type: :timestamptz, updated_at: false)
    end

    create index(:entries, [:transaction_id])
    # The account statement query: most recent first, for one account.
    create index(:entries, [:account_id, :inserted_at])
    create constraint(:entries, :entries_amount_nonzero, check: "amount_minor <> 0")

    create table(:balances, primary_key: false) do
      add :account_id,
          references(:accounts, type: :binary_id, on_delete: :restrict),
          primary_key: true

      add :amount_minor, :bigint, null: false, default: 0
      add :currency, :string, size: 3, null: false

      # Denormalised from accounts so the CHECK below can see it: a CHECK
      # constraint cannot read another table, and this rule is worth having in
      # the database rather than only in the code that writes to it.
      add :allow_negative, :boolean, null: false

      # Optimistic concurrency. Postings hold an in-process lock on the
      # account, so this should never fire -- which is exactly why it is here.
      # If the lock manager ever has a bug, this turns silent corruption into a
      # failed transaction.
      add :version, :bigint, null: false, default: 0

      timestamps(type: :timestamptz, inserted_at: false)
    end

    create constraint(:balances, :balances_not_negative,
             check: "allow_negative OR amount_minor >= 0"
           )
  end
end
