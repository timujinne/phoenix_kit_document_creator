defmodule PhoenixKitDocumentCreator.Web.CategoriesLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.Taxonomy

  test "lists existing categories", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, _} = Taxonomy.create_category(%{name: "Financial"})
    {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")
    assert render(view) =~ "Financial"
  end

  test "selecting a category shows its types", %{conn: conn} do
    conn = put_test_scope(conn, fake_scope())
    {:ok, cat} = Taxonomy.create_category(%{name: "C"})
    {:ok, _} = Taxonomy.create_type(%{name: "InvoiceType", category_uuid: cat.uuid})
    {:ok, view, _html} = live(conn, "/en/admin/document-creator/categories")

    view
    |> element("button[phx-click='select_category'][phx-value-uuid='#{cat.uuid}']")
    |> render_click()

    assert render(view) =~ "InvoiceType"
  end
end
