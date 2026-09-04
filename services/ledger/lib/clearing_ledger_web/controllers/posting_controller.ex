defmodule Clearing.LedgerWeb.PostingController do
  use Clearing.LedgerWeb, :controller

  alias Clearing.Ledger.Postings

  action_fallback Clearing.LedgerWeb.FallbackController

  def create(conn, params), do: posted(conn, Postings.post(params))
  def transfer(conn, params), do: posted(conn, Postings.transfer(params))

  def show(conn, %{"id" => id}) do
    with {:ok, transaction} <- Postings.fetch(id) do
      render(conn, :show, transaction: transaction, outcome: :found)
    end
  end

  # 201 for work that was done, 200 for a replay. The body is identical either
  # way, so a client that ignores the distinction still behaves correctly --
  # but one that cares can tell whether its retry was the one that landed.
  defp posted(conn, {:ok, transaction, :posted}) do
    conn
    |> put_status(:created)
    |> render(:show, transaction: transaction, outcome: :posted)
  end

  defp posted(conn, {:ok, transaction, :replayed}) do
    render(conn, :show, transaction: transaction, outcome: :replayed)
  end

  defp posted(_conn, {:error, _reason} = error), do: error
end
