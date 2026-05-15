defmodule PhoenixKitDocumentCreator.Web.CategoryFormLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.Taxonomy

  test "creates a category", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/new")

    view
    |> form("form", category: %{name: "Legal"})
    |> render_submit()

    assert [%{name: "Legal"}] = Taxonomy.list_categories()
  end

  test "edits an existing category", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, cat} = Taxonomy.create_category(%{name: "Old"})
    {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/edit")

    view |> form("form", category: %{name: "New"}) |> render_submit()

    assert Taxonomy.get_category(cat.uuid).name == "New"
  end
end
