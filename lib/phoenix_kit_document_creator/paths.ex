defmodule PhoenixKitDocumentCreator.Paths do
  @moduledoc """
  Centralized path helpers for the Document Creator module.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/document-creator"

  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @spec templates() :: String.t()
  def templates, do: Routes.path("#{@base}/templates")

  @spec documents() :: String.t()
  def documents, do: Routes.path("#{@base}/documents")

  @spec categories() :: String.t()
  def categories, do: Routes.path("#{@base}/categories")

  @spec settings() :: String.t()
  def settings, do: Routes.path("/admin/settings/document-creator")

  @doc """
  The core settings page holding the connections this module reads and writes.

  This module only ever deals in website-wide connections, so the page to send
  people to is core's website-wide Integrations page — never the personal one,
  which lives on the profile at `/profile/settings/integrations` and stores
  connections under a `{:user, uuid}` owner.

  Precisely: the listing call (`list_connections/2`) defaults to the `:system`
  owner, while the per-connection calls resolve owner-agnostically —
  `connected?/2` through `get_credentials/2`, and `get_integration/1`'s uuid
  branch straight through core's own `resolve_uuid(uuid, :any)`. Both land on
  `:any`, but every uuid handed to them was drawn from that `:system`-scoped
  listing, or is the module's own stored `google_connection`. Nothing here
  ever passes a `{:user, uuid}` owner, so no connection this module touches
  lives on the personal page.

  That website-wide page moved: it was `/admin/settings/integrations/website`
  until core 2.21.3 renamed it to `/admin/settings/integrations`, the
  `/website` segment having existed only to disambiguate it from the personal
  page that has since moved to the profile. The two links live here rather
  than inline in a template so the next rename is one edit with a test on it,
  not a string to find in HEEx.
  """
  @spec integrations() :: String.t()
  def integrations, do: Routes.path("/admin/settings/integrations")

  @doc "Core's \"add a connection\" form, same scope as `integrations/0`."
  @spec new_integration() :: String.t()
  def new_integration, do: Routes.path("/admin/settings/integrations/new")
end
