defmodule Clearing.Ledger.Money do
  @moduledoc """
  Money is an integer count of minor units, and nothing else.

  No floats: `0.1 + 0.2` is not `0.3` in binary floating point, and a ledger
  that is wrong in the seventh decimal place is wrong. No decimal strings
  passed around either -- a string is a representation, and every function that
  accepts one eventually meets one it parses differently. Amounts enter here as
  integers, are stored as `bigint`, and are turned back into text exactly once,
  at the edge, by `format/2`.

  Sign carries direction: negative is a debit, positive is a credit. A
  transaction's entries sum to zero, which is only expressible if debits and
  credits live on the same number line.
  """

  @typedoc "A signed amount in the currency's minor unit (centavos, cents, yen)."
  @type minor :: integer()
  @type currency :: String.t()

  # ISO 4217 exponents for the currencies this ledger accepts. The list is
  # short on purpose: an unknown code is rejected rather than assumed to have
  # two decimal places, because JPY has none and guessing wrong is a
  # hundredfold error in the direction nobody notices until settlement.
  @exponents %{"BRL" => 2, "USD" => 2, "EUR" => 2, "GBP" => 2, "JPY" => 0}

  # bigint. Anything outside this cannot be stored, so it is refused at the
  # boundary rather than by the database three layers down.
  @max_minor 9_223_372_036_854_775_807
  @min_minor -9_223_372_036_854_775_808

  @doc "Every currency code this ledger will accept, sorted."
  @spec currencies() :: [currency()]
  def currencies, do: @exponents |> Map.keys() |> Enum.sort()

  @doc "Whether `code` is a currency this ledger accepts."
  @spec known?(term()) :: boolean()
  def known?(code) when is_binary(code), do: Map.has_key?(@exponents, code)
  def known?(_), do: false

  @doc """
  The number of decimal places in `code`'s minor unit.

      iex> Clearing.Ledger.Money.exponent("BRL")
      {:ok, 2}

      iex> Clearing.Ledger.Money.exponent("JPY")
      {:ok, 0}

      iex> Clearing.Ledger.Money.exponent("XYZ")
      :error
  """
  @spec exponent(term()) :: {:ok, non_neg_integer()} | :error
  def exponent(code) when is_binary(code), do: Map.fetch(@exponents, code)
  def exponent(_), do: :error

  @doc """
  Validates an amount arriving from outside as minor units.

  Rejects non-integers so that a JSON body carrying `12.34` -- which a client
  meant as reais and this ledger would otherwise round -- fails loudly instead.
  """
  @spec cast(term()) :: {:ok, minor()} | {:error, :not_an_integer | :out_of_range}
  def cast(value) when is_integer(value) and value >= @min_minor and value <= @max_minor,
    do: {:ok, value}

  def cast(value) when is_integer(value), do: {:error, :out_of_range}
  def cast(_), do: {:error, :not_an_integer}

  @doc """
  Renders minor units as a decimal string. The only place money becomes text.

      iex> Clearing.Ledger.Money.format(1234, "BRL")
      {:ok, "12.34"}

      iex> Clearing.Ledger.Money.format(-5, "USD")
      {:ok, "-0.05"}

      iex> Clearing.Ledger.Money.format(1234, "JPY")
      {:ok, "1234"}
  """
  @spec format(minor(), currency()) :: {:ok, String.t()} | :error
  def format(minor, currency) when is_integer(minor) do
    with {:ok, places} <- exponent(currency) do
      {:ok, render(minor, places)}
    end
  end

  def format(_, _), do: :error

  defp render(minor, 0), do: Integer.to_string(minor)

  defp render(minor, places) do
    sign = if minor < 0, do: "-", else: ""
    scale = pow10(places)
    magnitude = abs(minor)

    fraction =
      magnitude
      |> rem(scale)
      |> Integer.to_string()
      |> String.pad_leading(places, "0")

    "#{sign}#{div(magnitude, scale)}.#{fraction}"
  end

  @doc """
  Parses a decimal string into minor units, exactly or not at all.

  `"12.5"` in a two-place currency is 1250 -- a trailing zero is implied and
  unambiguous. `"12.345"` is refused rather than rounded: rounding here would
  make the ledger disagree with the number the caller sent, and there is no
  good answer to "which way did it go".

      iex> Clearing.Ledger.Money.parse("12.34", "BRL")
      {:ok, 1234}

      iex> Clearing.Ledger.Money.parse("-0.05", "USD")
      {:ok, -5}

      iex> Clearing.Ledger.Money.parse("12.345", "BRL")
      {:error, :too_precise}
  """
  @spec parse(term(), currency()) ::
          {:ok, minor()} | {:error, :malformed | :too_precise | :out_of_range | :unknown_currency}
  def parse(text, currency) when is_binary(text) do
    case exponent(currency) do
      {:ok, places} -> parse_places(String.trim(text), places)
      :error -> {:error, :unknown_currency}
    end
  end

  def parse(_, _), do: {:error, :malformed}

  defp parse_places(text, places) do
    with {:ok, sign, digits, fraction} <- split(text),
         {:ok, scaled} <- scale_fraction(fraction, places) do
      combine(sign, digits, scaled, places)
    end
  end

  defp split(text) do
    case Regex.run(~r/\A([+-]?)(\d+)(?:\.(\d+))?\z/, text) do
      [_, sign, digits] -> {:ok, sign, digits, ""}
      [_, sign, digits, fraction] -> {:ok, sign, digits, fraction}
      nil -> {:error, :malformed}
    end
  end

  defp scale_fraction(fraction, places) when byte_size(fraction) > places,
    do: {:error, :too_precise}

  defp scale_fraction("", 0), do: {:ok, 0}
  defp scale_fraction(fraction, places), do: {:ok, pad_to(fraction, places)}

  defp pad_to(fraction, places) do
    fraction |> String.pad_trailing(places, "0") |> String.to_integer()
  end

  defp combine(sign, digits, fraction, places) do
    magnitude = String.to_integer(digits) * pow10(places) + fraction
    cast(if sign == "-", do: -magnitude, else: magnitude)
  end

  defp pow10(0), do: 1
  defp pow10(n), do: Integer.pow(10, n)
end
