defmodule PhoenixKitDocumentCreator.Web.Helpers do
  @moduledoc """
  Cross-LiveView helpers for the Document Creator admin pages.
  """

  use Gettext, backend: PhoenixKitDocumentCreator.Gettext

  import Phoenix.Component, only: [assign: 2]

  alias PhoenixKitDocumentCreator.Paths
  alias PhoenixKitDocumentCreator.Taxonomy

  @doc """
  Sets the admin header's trail for a page under the module: the section
  is `Document Creator` linking to the landing page, `crumbs` are every
  level between it and this page (top down), and `title` names this page
  only — the bar draws the separators. The landing page itself sets
  `page_title` alone, with no section.
  """
  @spec assign_trail(Phoenix.LiveView.Socket.t(), String.t(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def assign_trail(socket, title, crumbs \\ []) do
    assign(socket,
      page_section: gettext("Document Creator"),
      page_section_path: Paths.index(),
      page_crumbs: crumbs,
      page_title: title
    )
  end

  @doc "The crumb for the Categories list page."
  @spec categories_crumb() :: map()
  def categories_crumb, do: %{label: gettext("Categories"), path: Paths.categories()}

  @doc """
  A text crumb for a category or type, named in `locale` the way the
  list page names it. Text, not a link: the Categories list is the only
  page either record has.
  """
  @spec record_crumb(struct(), String.t() | nil) :: map()
  def record_crumb(record, locale), do: %{label: Taxonomy.localized_name(record, locale)}

  @doc """
  The actor opts list to thread into context-fn calls: `[actor_uuid: uuid]`
  for a signed-in user, otherwise `[]` — see `PhoenixKitWeb.Actor.opts/1`.
  Pass-through into mutating `Documents.*` functions for activity-log
  attribution.
  """
  @spec actor_opts(Phoenix.LiveView.Socket.t()) :: keyword()
  defdelegate actor_opts(socket), to: PhoenixKitWeb.Actor, as: :opts

  @doc "The acting user's uuid, or `nil` — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defdelegate actor_uuid(socket), to: PhoenixKitWeb.Actor, as: :uuid
end
