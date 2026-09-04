defmodule Clearing.Ledger.Repo.Migrations.AddDoubleEntryInvariants do
  use Ecto.Migration

  @moduledoc """
  The rule that makes this a ledger rather than a table of numbers: the entries
  of a transaction sum to zero, per currency.

  It is a DEFERRABLE INITIALLY DEFERRED constraint trigger, so it runs once at
  COMMIT rather than after each row. That matters: entries are inserted one at
  a time, and every intermediate state of a transfer is unbalanced. Checking
  eagerly would reject every correct posting.

  Putting it in the database rather than only in Elixir means it also holds for
  a migration, a psql session, a future service, and any bug in the code above.
  """

  def up do
    execute """
    CREATE OR REPLACE FUNCTION assert_transaction_balanced() RETURNS trigger AS $$
    DECLARE
      offending RECORD;
    BEGIN
      SELECT e.currency, SUM(e.amount_minor) AS total
        INTO offending
        FROM entries e
       WHERE e.transaction_id = COALESCE(NEW.transaction_id, OLD.transaction_id)
       GROUP BY e.currency
      HAVING SUM(e.amount_minor) <> 0
       LIMIT 1;

      IF FOUND THEN
        RAISE EXCEPTION
          'transaction % is unbalanced in %: entries sum to %',
          COALESCE(NEW.transaction_id, OLD.transaction_id),
          offending.currency,
          offending.total
        USING ERRCODE = 'check_violation',
              CONSTRAINT = 'entries_balanced';
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE CONSTRAINT TRIGGER entries_balanced
      AFTER INSERT OR UPDATE OR DELETE ON entries
      DEFERRABLE INITIALLY DEFERRED
      FOR EACH ROW EXECUTE FUNCTION assert_transaction_balanced();
    """

    # An entry must be in the currency of the account it lands on. Without
    # this, a EUR entry on a BRL account would balance against another EUR
    # entry and quietly corrupt both balances.
    execute """
    CREATE OR REPLACE FUNCTION assert_entry_currency_matches_account() RETURNS trigger AS $$
    DECLARE
      account_currency text;
    BEGIN
      SELECT a.currency INTO account_currency FROM accounts a WHERE a.id = NEW.account_id;

      IF account_currency IS DISTINCT FROM NEW.currency THEN
        RAISE EXCEPTION
          'entry currency % does not match account % currency %',
          NEW.currency, NEW.account_id, account_currency
        USING ERRCODE = 'check_violation',
              CONSTRAINT = 'entries_currency_matches_account';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER entries_currency_matches_account
      BEFORE INSERT OR UPDATE ON entries
      FOR EACH ROW EXECUTE FUNCTION assert_entry_currency_matches_account();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS entries_currency_matches_account ON entries"
    execute "DROP FUNCTION IF EXISTS assert_entry_currency_matches_account()"
    execute "DROP TRIGGER IF EXISTS entries_balanced ON entries"
    execute "DROP FUNCTION IF EXISTS assert_transaction_balanced()"
  end
end
