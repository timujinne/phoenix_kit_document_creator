defmodule PhoenixKitDocumentCreator.Web.EditViewingLanguageTest do
  @moduledoc """
  An edit form opens on the language tab of the language the admin is
  viewing the page in; a new record still starts on the main language,
  which holds its required fields. The open tab is read from the rendered
  name input: the main language posts `x[name]`, any other `x[lang_name]`.
  """
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitDocumentCreator.Taxonomy

  @base "/en/admin/document-creator"

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")

    {:ok, category} = Taxonomy.create_category(%{name: "Legal"})
    {:ok, type} = Taxonomy.create_type(%{name: "Contract", category_uuid: category.uuid})

    %{
      conn: put_test_scope(conn, fake_scope()),
      category: category,
      type: type
    }
  end

  test "viewed in French, an edit form opens on the French tab", ctx do
    conn = with_request_locale(ctx.conn, "fr-FR")

    for {path, prefix} <- [
          {"#{@base}/categories/#{ctx.category.uuid}/edit", "category"},
          {"#{@base}/types/#{ctx.type.uuid}/edit", "type"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s(name="#{prefix}[lang_name]"), path
      refute html =~ ~s(name="#{prefix}[name]"), path
    end
  end

  test "viewed in French, a new record starts on the main tab", ctx do
    conn = with_request_locale(ctx.conn, "fr-FR")

    for {path, prefix} <- [
          {"#{@base}/categories/new", "category"},
          {"#{@base}/categories/#{ctx.category.uuid}/types/new", "type"}
        ] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ ~s(name="#{prefix}[name]"), path
    end
  end
end
