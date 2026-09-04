defmodule Clearing.Ledger.MoneyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Clearing.Ledger.Money

  doctest Clearing.Ledger.Money

  describe "known?/1 and currencies/0" do
    test "accepts the currencies this ledger supports" do
      for code <- Money.currencies(), do: assert(Money.known?(code))
    end

    test "rejects anything else, including things shaped like a currency" do
      for code <- ["XYZ", "brl", "BR", "BRLL", "", nil, 978, :BRL] do
        refute Money.known?(code)
      end
    end
  end

  describe "exponent/1" do
    test "knows that yen has no minor unit" do
      assert Money.exponent("JPY") == {:ok, 0}
      assert Money.exponent("BRL") == {:ok, 2}
      assert Money.exponent("XYZ") == :error
      assert Money.exponent(nil) == :error
    end
  end

  describe "cast/1" do
    test "accepts integers inside the bigint range" do
      for value <- [0, 1, -1, 9_223_372_036_854_775_807, -9_223_372_036_854_775_808] do
        assert Money.cast(value) == {:ok, value}
      end
    end

    test "refuses values the database could not store" do
      assert Money.cast(9_223_372_036_854_775_808) == {:error, :out_of_range}
      assert Money.cast(-9_223_372_036_854_775_809) == {:error, :out_of_range}
    end

    test "refuses a float, rather than rounding one" do
      # A client sending 12.34 meant reais, not centavos. Rounding it here
      # would post 12 centavos and look like it worked.
      assert Money.cast(12.34) == {:error, :not_an_integer}
      assert Money.cast("1234") == {:error, :not_an_integer}
      assert Money.cast(nil) == {:error, :not_an_integer}
    end
  end

  describe "format/2" do
    test "renders minor units for each supported shape" do
      cases = [
        {1234, "BRL", "12.34"},
        {-1234, "BRL", "-12.34"},
        {5, "USD", "0.05"},
        {-5, "USD", "-0.05"},
        {0, "EUR", "0.00"},
        {100, "GBP", "1.00"},
        {1234, "JPY", "1234"},
        {-1234, "JPY", "-1234"},
        {0, "JPY", "0"}
      ]

      for {minor, currency, expected} <- cases do
        assert Money.format(minor, currency) == {:ok, expected},
               "#{minor} #{currency} should render as #{expected}"
      end
    end

    test "refuses an unknown currency and a non-integer amount" do
      assert Money.format(1234, "XYZ") == :error
      assert Money.format(12.34, "BRL") == :error
    end
  end

  describe "parse/2" do
    test "reads decimal strings into minor units" do
      cases = [
        {"12.34", "BRL", 1234},
        {"-12.34", "BRL", -1234},
        {"+12.34", "BRL", 1234},
        {"12.5", "BRL", 1250},
        {"12", "BRL", 1200},
        {"0.05", "USD", 5},
        {"  7.00  ", "USD", 700},
        {"1234", "JPY", 1234},
        {"-0.01", "EUR", -1}
      ]

      for {text, currency, expected} <- cases do
        assert Money.parse(text, currency) == {:ok, expected},
               "#{inspect(text)} #{currency} should parse to #{expected}"
      end
    end

    test "refuses more precision than the currency has, rather than rounding" do
      assert Money.parse("12.345", "BRL") == {:error, :too_precise}
      assert Money.parse("1.5", "JPY") == {:error, :too_precise}
    end

    test "refuses anything that is not a plain decimal number" do
      for text <- ["", "abc", "12.", ".34", "1,234.00", "1 234", "12.34.56", "0x10", "1e3"] do
        assert Money.parse(text, "BRL") == {:error, :malformed},
               "#{inspect(text)} should be rejected"
      end

      assert Money.parse(nil, "BRL") == {:error, :malformed}
      assert Money.parse(1234, "BRL") == {:error, :malformed}
    end

    test "refuses an unknown currency before looking at the number" do
      assert Money.parse("12.34", "XYZ") == {:error, :unknown_currency}
    end

    test "refuses a value too large for the database" do
      assert Money.parse("92233720368547758.08", "BRL") == {:error, :out_of_range}
    end
  end

  describe "format and parse together" do
    property "parsing what was formatted gives back the same amount" do
      check all(
              minor <- integer(-1_000_000_000..1_000_000_000),
              currency <- member_of(Money.currencies())
            ) do
        {:ok, text} = Money.format(minor, currency)
        assert Money.parse(text, currency) == {:ok, minor}
      end
    end

    property "formatting never loses the sign of a non-zero amount" do
      check all(
              minor <- integer(-1_000_000..1_000_000),
              minor != 0,
              currency <- member_of(Money.currencies())
            ) do
        {:ok, text} = Money.format(minor, currency)
        assert String.starts_with?(text, "-") == minor < 0
      end
    end
  end
end
