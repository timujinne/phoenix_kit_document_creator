defmodule PhoenixKitDocumentCreator.Test.ProjectsMigration do
  @moduledoc """
  Test-boot wrapper around Projects' migration chain (a test-only dependency),
  run through `Ecto.Migrator` like `SchemaMigration` runs this module's own.
  """

  use Ecto.Migration

  alias PhoenixKitProjects.Migrations.Schema

  def up, do: Schema.up(prefix: "public")
  def down, do: :ok
end
