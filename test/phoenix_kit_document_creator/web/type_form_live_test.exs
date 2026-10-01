defmodule PhoenixKitDocumentCreator.Web.TypeFormLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.Taxonomy

  @page "/en/admin/document-creator/categories"

  setup %{conn: conn} do
    {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})
    %{conn: put_test_scope(conn, fake_scope()), cat: cat}
  end

  describe "back to the Categories page with the type's category selected" do
    test "a new type: Cancel, the back arrow and the save", %{conn: conn, cat: cat} do
      back = @page <> "?category=#{cat.uuid}"
      {:ok, view, _} = live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/types/new")

      assert has_element?(view, ~s{a[href="#{back}"]}, "Cancel")
      assert has_element?(view, ~s{a[href="#{back}"] .hero-arrow-left})

      view
      |> form("#type-form", type: %{name: "Contract", category_uuid: cat.uuid})
      |> render_submit()

      assert_redirect(view, back)
      assert [%{name: "Contract"}] = Taxonomy.list_types_for_category(cat.uuid)
    end

    test "a type moved to another category lands on the new one", %{conn: conn, cat: cat} do
      {:ok, other} = Taxonomy.create_category(%{name: "Other"})
      {:ok, type} = Taxonomy.create_type(%{name: "Contract", category_uuid: cat.uuid})
      {:ok, view, _} = live(conn, "/en/admin/document-creator/types/#{type.uuid}/edit")

      # Until saved, leaving goes back where the type is.
      assert has_element?(view, ~s{a[href="#{@page}?category=#{cat.uuid}"]}, "Cancel")

      view
      |> form("#type-form", type: %{name: "Contract", category_uuid: other.uuid})
      |> render_submit()

      assert_redirect(view, @page <> "?category=#{other.uuid}")
    end

    test "a permanently deleted type goes back to its category", %{conn: conn, cat: cat} do
      {:ok, type} = Taxonomy.create_type(%{name: "Contract", category_uuid: cat.uuid})
      {:ok, view, _} = live(conn, "/en/admin/document-creator/types/#{type.uuid}/edit")

      view |> element("button[phx-click='delete_forever']") |> render_click()

      assert_redirect(view, @page <> "?category=#{cat.uuid}")
      assert Taxonomy.get_type(type.uuid) == nil
    end
  end
end
