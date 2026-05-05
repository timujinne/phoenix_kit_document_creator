defmodule PhoenixKitDocumentCreator.Web.Helpers do
  @moduledoc """
  Cross-LiveView helpers for the Document Creator admin pages.
  """

  @doc """
  Build the actor opts list to thread into context-fn calls.

  Returns `[actor_uuid: uuid]` when the LV's `phoenix_kit_current_scope`
  assign carries a user, otherwise `[]`. Pass-through into mutating
  `Documents.*` functions for activity-log attribution.
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  def actor_opts(socket) do
    case actor_uuid(socket) do
      nil -> []
      uuid -> [actor_uuid: uuid]
    end
  end

  @doc """
  Pull the acting user's UUID out of the LV scope, or `nil` when not signed in.
  """
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end
end
