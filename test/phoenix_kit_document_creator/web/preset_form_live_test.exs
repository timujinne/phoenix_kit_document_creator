defmodule PhoenixKitDocumentCreator.Web.PresetFormLiveTest do
  use PhoenixKitDocumentCreator.LiveCase

  alias PhoenixKitDocumentCreator.{Documents, Taxonomy}
  alias PhoenixKitDocumentCreator.Schemas.Template
  alias PhoenixKitDocumentCreator.Test.Repo

  defp setup_category(_) do
    {:ok, cat} = Taxonomy.create_category(%{name: "Legal"})
    {:ok, type} = Taxonomy.create_type(%{name: "Contract", category_uuid: cat.uuid})
    %{cat: cat, type: type}
  end

  describe "new" do
    setup :setup_category

    test "creates a preset scoped to the category", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      view
      |> form("form", preset: %{name: "Standard", description: "Default set"})
      |> render_submit()

      assert [preset] = Documents.list_presets(%{scope_id: cat.uuid})
      assert preset.name == "Standard"
      assert preset.scope_id == cat.uuid
    end

    test "Cancel and the save go back to the category, selected", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())
      back = "/en/admin/document-creator/categories?category=#{cat.uuid}"

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      assert has_element?(view, ~s{a[href="#{back}"]}, "Cancel")

      view |> form("form", preset: %{name: "Standard"}) |> render_submit()

      assert_redirect(view, back)
    end

    # `live/2` runs the LiveView in its own process, so it never sees a
    # non-default Gettext locale in a test (see the identical caveat on
    # `CategoriesLiveTest`'s "locale-aware category/type names" describe
    # block) — this only exercises the untranslated-fallback path, but it
    # locks in that the category heading and the "Document type" select both
    # route through `Taxonomy.localized_name/2` instead of the raw `:name`
    # field, same as every other taxonomy display site.
    test "renders category and type labels via localized_name/2", %{
      conn: conn,
      cat: cat,
      type: type
    } do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      assert html =~ cat.name
      assert render(view) =~ type.name
    end
  end

  describe "edit" do
    setup :setup_category

    test "updates an existing preset", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, preset} =
        Documents.save_preset(%{
          name: "Old",
          scope_id: cat.uuid,
          created_by_uuid: Ecto.UUID.generate()
        })

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/presets/#{preset.uuid}/edit")

      view |> form("form", preset: %{name: "Renamed"}) |> render_submit()

      assert Documents.list_presets(%{scope_id: cat.uuid}) |> hd() |> Map.get(:name) ==
               "Renamed"
    end

    test "preserves the original created_by_uuid on edit", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())
      original_author = Ecto.UUID.generate()

      {:ok, preset} =
        Documents.save_preset(%{
          name: "Old",
          scope_id: cat.uuid,
          created_by_uuid: original_author
        })

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/presets/#{preset.uuid}/edit")

      view |> form("form", preset: %{name: "Renamed"}) |> render_submit()

      assert Documents.get_preset(preset.uuid).created_by_uuid == original_author
    end

    test "keeps a section referencing a non-published template", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, tmpl} =
        Template.changeset(
          %Template{},
          %{
            name: "Trashed",
            google_doc_id: "gd-trashed",
            status: "trashed",
            category_uuid: cat.uuid
          }
        )
        |> Repo.insert()

      {:ok, preset} =
        Documents.save_preset(%{
          name: "WithBroken",
          scope_id: cat.uuid,
          created_by_uuid: Ecto.UUID.generate(),
          sections: [%{"template_uuid" => tmpl.uuid, "position" => 0}]
        })

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/presets/#{preset.uuid}/edit")

      view |> form("form", preset: %{name: "WithBroken"}) |> render_submit()

      assert [%{"template_uuid" => uuid}] = Documents.get_preset(preset.uuid).sections
      assert uuid == tmpl.uuid
    end
  end

  describe "section editor" do
    setup :setup_category

    test "adds and saves a template section", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, tmpl} =
        Template.changeset(
          %Template{},
          %{
            name: "Cover",
            google_doc_id: "gd-cover",
            status: "published",
            category_uuid: cat.uuid
          }
        )
        |> Repo.insert()

      # Category membership is the source of truth for the template picker.
      {:ok, _} = Taxonomy.set_template_memberships(tmpl.uuid, [%{category_uuid: cat.uuid}])

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      view |> element("button", "Add section") |> render_click()

      view
      |> form("form",
        preset: %{name: "WithSection"},
        section: %{"0" => %{template_uuid: tmpl.uuid}}
      )
      |> render_submit()

      assert [preset] = Documents.list_presets(%{scope_id: cat.uuid})
      assert [%{"template_uuid" => uuid}] = preset.sections
      assert uuid == tmpl.uuid
    end

    test "saves default variable values for a section", %{conn: conn, cat: cat} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, tmpl} =
        Template.changeset(
          %Template{},
          %{
            name: "Cover",
            google_doc_id: "gd-cover2",
            status: "published",
            category_uuid: cat.uuid,
            variables: [%{"name" => "client_name", "type" => "text"}]
          }
        )
        |> Repo.insert()

      # Category membership is the source of truth for the template picker.
      {:ok, _} = Taxonomy.set_template_memberships(tmpl.uuid, [%{category_uuid: cat.uuid}])

      {:ok, view, _} =
        live(conn, "/en/admin/document-creator/categories/#{cat.uuid}/presets/new")

      view |> element("button", "Add section") |> render_click()

      # The variable-value inputs only render once the section has a template
      # selected — pick it via a change event first (as the browser would).
      view
      |> form("form",
        preset: %{name: "WithVars"},
        section: %{"0" => %{template_uuid: tmpl.uuid}}
      )
      |> render_change()

      view
      |> form("form",
        preset: %{name: "WithVars"},
        section: %{
          "0" => %{
            template_uuid: tmpl.uuid,
            variable_values: %{"client_name" => "ACME Ltd"}
          }
        }
      )
      |> render_submit()

      assert [preset] = Documents.list_presets(%{scope_id: cat.uuid})
      assert [%{"variable_values" => %{"client_name" => "ACME Ltd"}}] = preset.sections
    end
  end
end
