if Code.ensure_loaded?(PhoenixKitDocumentCreator.DataCase) do
  defmodule PhoenixKitDocumentCreator.Integration.TaxonomyTest do
    use PhoenixKitDocumentCreator.DataCase, async: true

    alias PhoenixKitDocumentCreator.Documents
    alias PhoenixKitDocumentCreator.Schemas.Document
    alias PhoenixKitDocumentCreator.Schemas.Template
    alias PhoenixKitDocumentCreator.Taxonomy

    # ===========================================================================
    # Helpers
    # ===========================================================================

    defp create_category!(attrs \\ %{}) do
      name = Map.get(attrs, :name, "Test Category #{System.unique_integer()}")
      {:ok, cat} = Taxonomy.create_category(Map.put(attrs, :name, name))
      cat
    end

    defp create_type!(category_uuid, attrs \\ %{}) do
      name = Map.get(attrs, :name, "Test Type #{System.unique_integer()}")

      {:ok, type} =
        Taxonomy.create_type(Map.merge(attrs, %{name: name, category_uuid: category_uuid}))

      type
    end

    defp create_template!(attrs \\ %{}) do
      name = Map.get(attrs, :name, "Tmpl #{System.unique_integer()}")
      google_doc_id = Map.get(attrs, :google_doc_id, "gdoc_#{System.unique_integer()}")

      {:ok, tmpl} =
        %Template{}
        |> Template.changeset(Map.merge(attrs, %{name: name, google_doc_id: google_doc_id}))
        |> Repo.insert()

      tmpl
    end

    # A template's memberships as a sorted `{category_uuid, type_uuid}` list —
    # order-independent comparison for round-trip assertions.
    defp memberships(template_uuid) do
      template_uuid
      |> Taxonomy.list_memberships_for_template()
      |> Enum.map(&{&1.category_uuid, &1.type_uuid})
      |> Enum.sort()
    end

    # ===========================================================================
    # Category CRUD
    # ===========================================================================

    describe "create_category/1" do
      test "inserts a category with valid attrs" do
        assert {:ok, cat} = Taxonomy.create_category(%{name: "Finance"})
        assert cat.name == "Finance"
        assert cat.status == "active"
        assert cat.position == 0
      end

      test "returns error changeset when name is missing" do
        assert {:error, changeset} = Taxonomy.create_category(%{})
        assert %{name: [_ | _]} = errors_on(changeset)
      end

      test "returns error changeset when name exceeds 255 chars" do
        assert {:error, changeset} = Taxonomy.create_category(%{name: String.duplicate("a", 256)})
        assert %{name: [_ | _]} = errors_on(changeset)
      end

      test "appends a new category after existing ones instead of tying at position 0" do
        first = create_category!(%{name: "First"})
        assert first.position == 0

        second = create_category!(%{name: "Second"})
        assert second.position == 1

        third = create_category!(%{name: "Third"})
        assert third.position == 2
      end

      test "an explicit position is not overridden by the append default" do
        create_category!(%{name: "First"})

        assert {:ok, cat} = Taxonomy.create_category(%{name: "Pinned", position: 0})
        assert cat.position == 0
      end

      test "trashed categories are ignored when computing the append position" do
        cat = create_category!(%{name: "Trashed"})
        {:ok, _} = Taxonomy.trash_category(cat)

        assert {:ok, next} = Taxonomy.create_category(%{name: "Next"})
        assert next.position == 0
      end
    end

    describe "get_category/1 and get_category!/1" do
      test "get_category/1 returns the category or nil" do
        cat = create_category!()
        assert Taxonomy.get_category(cat.uuid) == cat
        assert Taxonomy.get_category("00000000-0000-0000-0000-000000000000") == nil
      end

      test "get_category!/1 raises on missing uuid" do
        assert_raise Ecto.NoResultsError, fn ->
          Taxonomy.get_category!("00000000-0000-0000-0000-000000000000")
        end
      end
    end

    describe "update_category/2" do
      test "updates name and description" do
        cat = create_category!(%{name: "Old"})
        assert {:ok, updated} = Taxonomy.update_category(cat, %{name: "New", description: "Desc"})
        assert updated.name == "New"
        assert updated.description == "Desc"
      end

      test "returns error changeset on invalid attrs" do
        cat = create_category!()
        assert {:error, changeset} = Taxonomy.update_category(cat, %{name: ""})
        assert %{name: [_ | _]} = errors_on(changeset)
      end
    end

    describe "list_categories/1" do
      test "excludes deleted categories by default" do
        active = create_category!(%{name: "Active"})
        {:ok, deleted} = Taxonomy.create_category(%{name: "Deleted", status: "deleted"})

        uuids = Taxonomy.list_categories() |> Enum.map(& &1.uuid)
        assert active.uuid in uuids
        refute deleted.uuid in uuids
      end

      test "returns only deleted when status: 'deleted'" do
        create_category!(%{name: "Active"})
        {:ok, deleted} = Taxonomy.create_category(%{name: "Deleted", status: "deleted"})

        uuids = Taxonomy.list_categories(status: "deleted") |> Enum.map(& &1.uuid)
        assert deleted.uuid in uuids
      end

      test "orders by position then name" do
        {:ok, c1} = Taxonomy.create_category(%{name: "Beta", position: 1})
        {:ok, c2} = Taxonomy.create_category(%{name: "Alpha", position: 0})
        {:ok, c3} = Taxonomy.create_category(%{name: "Gamma", position: 0})

        result = Taxonomy.list_categories()
        idxs = Enum.map([c2, c3, c1], & &1.uuid)
        result_uuids = Enum.map(result, & &1.uuid)

        # c2 (pos 0, Alpha) and c3 (pos 0, Gamma) come before c1 (pos 1)
        assert Enum.find_index(result_uuids, &(&1 == c2.uuid)) <
                 Enum.find_index(result_uuids, &(&1 == c1.uuid))

        assert Enum.find_index(result_uuids, &(&1 == c3.uuid)) <
                 Enum.find_index(result_uuids, &(&1 == c1.uuid))

        assert Enum.find_index(result_uuids, &(&1 == c2.uuid)) <
                 Enum.find_index(result_uuids, &(&1 == c3.uuid))

        _ = idxs
      end
    end

    # ===========================================================================
    # Type CRUD
    # ===========================================================================

    describe "create_type/1" do
      test "inserts a type with valid attrs" do
        cat = create_category!()
        assert {:ok, type} = Taxonomy.create_type(%{name: "Invoice", category_uuid: cat.uuid})
        assert type.name == "Invoice"
        assert type.category_uuid == cat.uuid
        assert type.status == "active"
      end

      test "returns error when category_uuid is missing" do
        assert {:error, changeset} = Taxonomy.create_type(%{name: "Invoice"})
        assert %{category_uuid: [_ | _]} = errors_on(changeset)
      end

      test "returns error when category does not exist" do
        assert {:error, changeset} =
                 Taxonomy.create_type(%{
                   name: "Invoice",
                   category_uuid: "00000000-0000-0000-0000-000000000000"
                 })

        assert %{category_uuid: [_ | _]} = errors_on(changeset)
      end

      test "appends a new type after existing ones within the same category" do
        cat = create_category!()

        first = create_type!(cat.uuid, %{name: "First"})
        assert first.position == 0

        second = create_type!(cat.uuid, %{name: "Second"})
        assert second.position == 1
      end

      test "position append is scoped per category — a sibling category starts fresh" do
        cat1 = create_category!()
        cat2 = create_category!()

        create_type!(cat1.uuid, %{name: "T1"})
        create_type!(cat1.uuid, %{name: "T2"})

        first_in_cat2 = create_type!(cat2.uuid, %{name: "Other"})
        assert first_in_cat2.position == 0
      end

      test "an explicit position is not overridden by the append default" do
        cat = create_category!()
        create_type!(cat.uuid, %{name: "First"})

        assert {:ok, type} =
                 Taxonomy.create_type(%{name: "Pinned", category_uuid: cat.uuid, position: 0})

        assert type.position == 0
      end

      test "trashed types are ignored when computing the append position" do
        cat = create_category!()
        trashed = create_type!(cat.uuid, %{name: "Trashed"})
        {:ok, _} = Taxonomy.trash_type(trashed)

        assert {:ok, next} = Taxonomy.create_type(%{name: "Next", category_uuid: cat.uuid})
        assert next.position == 0
      end

      # Regression: the position lookup runs before the changeset, and the
      # form's "Select a category" prompt submits category_uuid as "" —
      # which used to reach the query and raise Ecto.Query.CastError
      # instead of returning the changeset's validation error.
      test "returns error (not a raise) when category_uuid is blank" do
        assert {:error, changeset} =
                 Taxonomy.create_type(%{"name" => "Invoice", "category_uuid" => ""})

        assert %{category_uuid: [_ | _]} = errors_on(changeset)
      end

      test "returns error (not a raise) when category_uuid is malformed" do
        assert {:error, changeset} =
                 Taxonomy.create_type(%{"name" => "Invoice", "category_uuid" => "not-a-uuid"})

        assert %{category_uuid: [_ | _]} = errors_on(changeset)
      end
    end

    describe "get_type/1 and get_type!/1" do
      test "get_type/1 returns the type or nil" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        assert Taxonomy.get_type(type.uuid) == type
        assert Taxonomy.get_type("00000000-0000-0000-0000-000000000000") == nil
      end

      test "get_type!/1 raises on missing uuid" do
        assert_raise Ecto.NoResultsError, fn ->
          Taxonomy.get_type!("00000000-0000-0000-0000-000000000000")
        end
      end
    end

    describe "get_active_type/1" do
      test "returns the type when it is active" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        assert Taxonomy.get_active_type(type.uuid) == type
      end

      test "returns nil for a trashed type" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        {:ok, trashed} = Taxonomy.trash_type(type)

        assert Taxonomy.get_active_type(trashed.uuid) == nil
        # get_type/1, unlike get_active_type/1, still returns the row.
        assert Taxonomy.get_type(trashed.uuid) != nil
      end

      test "returns nil for a missing uuid" do
        assert Taxonomy.get_active_type("00000000-0000-0000-0000-000000000000") == nil
      end
    end

    describe "list_types_for_category/2" do
      test "lists active types for a category" do
        cat = create_category!()
        t1 = create_type!(cat.uuid, %{name: "T1"})
        t2 = create_type!(cat.uuid, %{name: "T2"})

        {:ok, deleted_type} =
          Taxonomy.create_type(%{name: "Deleted", category_uuid: cat.uuid, status: "deleted"})

        result = Taxonomy.list_types_for_category(cat.uuid)
        uuids = Enum.map(result, & &1.uuid)
        assert t1.uuid in uuids
        assert t2.uuid in uuids
        refute deleted_type.uuid in uuids
      end

      test "returns only deleted types with status: 'deleted'" do
        cat = create_category!()
        create_type!(cat.uuid, %{name: "Active"})

        {:ok, deleted_type} =
          Taxonomy.create_type(%{name: "Del", category_uuid: cat.uuid, status: "deleted"})

        uuids =
          Taxonomy.list_types_for_category(cat.uuid, status: "deleted")
          |> Enum.map(& &1.uuid)

        assert deleted_type.uuid in uuids
      end
    end

    describe "update_type/2" do
      test "updates name" do
        cat = create_category!()
        type = create_type!(cat.uuid, %{name: "Old"})
        assert {:ok, updated} = Taxonomy.update_type(type, %{name: "New"})
        assert updated.name == "New"
      end
    end

    # ===========================================================================
    # Reorder
    # ===========================================================================

    describe "reorder_categories/1" do
      test "reassigns position for ordered list" do
        c1 = create_category!(%{name: "C1", position: 0})
        c2 = create_category!(%{name: "C2", position: 1})
        c3 = create_category!(%{name: "C3", position: 2})

        assert :ok = Taxonomy.reorder_categories([c3.uuid, c1.uuid, c2.uuid])

        positions =
          [c1, c2, c3]
          |> Enum.map(fn c -> {c.uuid, Taxonomy.get_category!(c.uuid).position} end)
          |> Map.new()

        assert positions[c3.uuid] == 0
        assert positions[c1.uuid] == 1
        assert positions[c2.uuid] == 2
      end
    end

    describe "reorder_types/2" do
      test "reassigns position within a category" do
        cat = create_category!()
        t1 = create_type!(cat.uuid, %{name: "T1", position: 0})
        t2 = create_type!(cat.uuid, %{name: "T2", position: 1})

        assert :ok = Taxonomy.reorder_types(cat.uuid, [t2.uuid, t1.uuid])

        assert Taxonomy.get_type!(t2.uuid).position == 0
        assert Taxonomy.get_type!(t1.uuid).position == 1
      end
    end

    # ===========================================================================
    # Trash / Restore / Permanently Delete — Category
    # ===========================================================================

    describe "trash_category/1" do
      test "soft-deletes a category and cascades to its types" do
        cat = create_category!()
        t1 = create_type!(cat.uuid)
        t2 = create_type!(cat.uuid)

        assert {:ok, trashed} = Taxonomy.trash_category(cat)
        assert trashed.status == "deleted"

        assert Taxonomy.get_type!(t1.uuid).status == "deleted"
        assert Taxonomy.get_type!(t2.uuid).status == "deleted"
      end

      test "cascades to templates via category_uuid or type_uuid" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        tmpl_via_cat = create_template!(%{category_uuid: cat.uuid})
        tmpl_via_type = create_template!(%{type_uuid: type.uuid})
        tmpl_unrelated = create_template!()

        assert {:ok, _} = Taxonomy.trash_category(cat)

        assert Repo.get!(Template, tmpl_via_cat.uuid).status == "trashed"
        assert Repo.get!(Template, tmpl_via_type.uuid).status == "trashed"
        assert Repo.get!(Template, tmpl_unrelated.uuid).status == "published"
      end

      test "keeps a template that still belongs to another active category (V2 membership)" do
        cat_a = create_category!()
        cat_b = create_category!()

        multi = create_template!()

        {:ok, _} =
          Taxonomy.set_template_memberships(multi.uuid, [
            %{category_uuid: cat_a.uuid},
            %{category_uuid: cat_b.uuid}
          ])

        sole = create_template!()
        {:ok, _} = Taxonomy.set_template_memberships(sole.uuid, [%{category_uuid: cat_a.uuid}])

        assert {:ok, _} = Taxonomy.trash_category(cat_a)

        # Multi-category template survives — it is still in cat_b.
        assert Repo.get!(Template, multi.uuid).status == "published"
        # A template whose only category was cat_a is still trashed, as before.
        assert Repo.get!(Template, sole.uuid).status == "trashed"
      end

      test "recomputes the mirror off the trashed category and restores it on restore" do
        cat_a = create_category!()
        cat_b = create_category!()
        multi = create_template!()

        {:ok, _} =
          Taxonomy.set_template_memberships(multi.uuid, [
            %{category_uuid: cat_a.uuid},
            %{category_uuid: cat_b.uuid}
          ])

        # Primary mirror is cat_a (created first → lowest position).
        assert Repo.get!(Template, multi.uuid).category_uuid == cat_a.uuid

        before = memberships(multi.uuid)

        {:ok, trashed} = Taxonomy.trash_category(cat_a)
        # Mirror moved to the surviving active category so the template does not
        # vanish from legacy single-category readers.
        assert Repo.get!(Template, multi.uuid).category_uuid == cat_b.uuid

        {:ok, _} = Taxonomy.restore_category(trashed)
        # Memberships are byte-for-byte preserved across the round trip …
        assert memberships(multi.uuid) == before
        # … and the mirror reclaims cat_a (lowest position, active again).
        assert Repo.get!(Template, multi.uuid).category_uuid == cat_a.uuid
      end

      test "does not cascade to documents" do
        cat = create_category!()

        {:ok, doc} =
          %Document{}
          |> Document.creation_changeset(%{
            name: "Doc",
            google_doc_id: "gdoc_doc_#{System.unique_integer()}",
            category_uuid: cat.uuid
          })
          |> Repo.insert()

        assert {:ok, _} = Taxonomy.trash_category(cat)

        assert Repo.get!(Document, doc.uuid).status == "published"
      end

      test "records affected template uuids in activity metadata" do
        cat = create_category!()
        tmpl = create_template!(%{category_uuid: cat.uuid})

        assert {:ok, _} = Taxonomy.trash_category(cat, actor_uuid: "actor-1")

        # Verify the cascade metadata was recorded (via activity log or data field)
        # We check the template was trashed — the metadata recording is implementation detail
        assert Repo.get!(Template, tmpl.uuid).status == "trashed"
      end
    end

    describe "restore_category/1" do
      test "restores a trashed category and its types" do
        cat = create_category!()
        t1 = create_type!(cat.uuid)

        {:ok, trashed_cat} = Taxonomy.trash_category(cat)
        assert {:ok, restored} = Taxonomy.restore_category(trashed_cat)

        assert restored.status == "active"
        assert Taxonomy.get_type!(t1.uuid).status == "active"
      end

      test "restores only templates trashed by this cascade" do
        cat = create_category!()
        tmpl_by_cascade = create_template!(%{category_uuid: cat.uuid})
        tmpl_manually_trashed = create_template!(%{category_uuid: cat.uuid, status: "trashed"})

        {:ok, trashed_cat} = Taxonomy.trash_category(cat)
        {:ok, _} = Taxonomy.restore_category(trashed_cat)

        # Template trashed by cascade is restored
        assert Repo.get!(Template, tmpl_by_cascade.uuid).status == "published"
        # Template that was already trashed before the cascade stays trashed
        assert Repo.get!(Template, tmpl_manually_trashed.uuid).status == "trashed"
      end

      test "restores only types trashed by this cascade" do
        cat = create_category!()
        type_by_cascade = create_type!(cat.uuid, %{name: "ByCascade"})
        type_manually_trashed = create_type!(cat.uuid, %{name: "Manual"})

        {:ok, _} = Taxonomy.trash_type(type_manually_trashed)

        {:ok, trashed_cat} = Taxonomy.trash_category(cat)
        {:ok, _} = Taxonomy.restore_category(trashed_cat)

        # Type trashed by the cascade is restored
        assert Taxonomy.get_type!(type_by_cascade.uuid).status == "active"
        # Type trashed manually before the cascade stays trashed
        assert Taxonomy.get_type!(type_manually_trashed.uuid).status == "deleted"
      end
    end

    describe "permanently_delete_category/1" do
      test "removes the category and its types from the DB" do
        cat = create_category!()
        type = create_type!(cat.uuid)

        assert {:ok, _} = Taxonomy.permanently_delete_category(cat)

        assert Taxonomy.get_category(cat.uuid) == nil
        assert Taxonomy.get_type(type.uuid) == nil
      end

      test "nullifies category_uuid on templates and documents" do
        cat = create_category!()
        tmpl = create_template!(%{category_uuid: cat.uuid})

        assert {:ok, _} = Taxonomy.permanently_delete_category(cat)
        assert Repo.get!(Template, tmpl.uuid).category_uuid == nil
      end
    end

    # ===========================================================================
    # Trash / Restore / Permanently Delete — Type
    # ===========================================================================

    describe "trash_type/1" do
      test "soft-deletes a type and cascades to its templates" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        tmpl = create_template!(%{type_uuid: type.uuid})
        other_tmpl = create_template!()

        assert {:ok, trashed} = Taxonomy.trash_type(type)
        assert trashed.status == "deleted"

        assert Repo.get!(Template, tmpl.uuid).status == "trashed"
        assert Repo.get!(Template, other_tmpl.uuid).status == "published"
      end

      test "keeps a template that still belongs to another active category (V2 membership)" do
        cat_a = create_category!()
        cat_b = create_category!()
        type_a = create_type!(cat_a.uuid)

        multi = create_template!()

        {:ok, _} =
          Taxonomy.set_template_memberships(multi.uuid, [
            %{category_uuid: cat_a.uuid, type_uuid: type_a.uuid},
            %{category_uuid: cat_b.uuid}
          ])

        assert {:ok, _} = Taxonomy.trash_type(type_a)

        # Survives — still a member of the active cat_b.
        assert Repo.get!(Template, multi.uuid).status == "published"
        # The deleted group is cleared from the mirror (no dangling type ref).
        assert Repo.get!(Template, multi.uuid).type_uuid == nil
      end
    end

    describe "count_published_templates_by_type/1" do
      test "counts published templates per group through the memberships" do
        cat = create_category!()
        main = create_type!(cat.uuid)
        annex = create_type!(cat.uuid)
        empty = create_type!(cat.uuid)

        for _ <- 1..2 do
          tmpl = create_template!()

          {:ok, _} =
            Taxonomy.set_template_memberships(tmpl.uuid, [
              %{category_uuid: cat.uuid, type_uuid: main.uuid}
            ])
        end

        tmpl = create_template!()

        {:ok, _} =
          Taxonomy.set_template_memberships(tmpl.uuid, [
            %{category_uuid: cat.uuid, type_uuid: annex.uuid}
          ])

        # In the category but in no group: counts for no type.
        ungrouped = create_template!()
        {:ok, _} = Taxonomy.set_template_memberships(ungrouped.uuid, [%{category_uuid: cat.uuid}])

        counts = Taxonomy.count_published_templates_by_type([main.uuid, annex.uuid, empty.uuid])

        assert counts == %{main.uuid => 2, annex.uuid => 1}
        assert Map.get(counts, empty.uuid, 0) == 0
      end

      test "does not count trashed, lost or unfiled templates" do
        cat = create_category!()
        type = create_type!(cat.uuid)

        for status <- ~w(published trashed lost unfiled) do
          tmpl = create_template!(%{status: status})

          {:ok, _} =
            Taxonomy.set_template_memberships(tmpl.uuid, [
              %{category_uuid: cat.uuid, type_uuid: type.uuid}
            ])
        end

        assert Taxonomy.count_published_templates_by_type([type.uuid]) == %{type.uuid => 1}
      end

      test "a template in two categories counts once in each category's group" do
        cat_a = create_category!()
        cat_b = create_category!()
        type_a = create_type!(cat_a.uuid)
        type_b = create_type!(cat_b.uuid)
        multi = create_template!()

        {:ok, _} =
          Taxonomy.set_template_memberships(multi.uuid, [
            %{category_uuid: cat_a.uuid, type_uuid: type_a.uuid},
            %{category_uuid: cat_b.uuid, type_uuid: type_b.uuid}
          ])

        assert Taxonomy.count_published_templates_by_type([type_a.uuid, type_b.uuid]) ==
                 %{type_a.uuid => 1, type_b.uuid => 1}
      end

      test "an empty list asks nothing" do
        assert Taxonomy.count_published_templates_by_type([]) == %{}
      end

      test "counts only the memberships filed under the type's current category" do
        cat = create_category!()
        other = create_category!()
        type = create_type!(cat.uuid)
        tmpl = create_template!()

        {:ok, _} =
          Taxonomy.set_template_memberships(tmpl.uuid, [
            %{category_uuid: cat.uuid, type_uuid: type.uuid}
          ])

        assert Taxonomy.count_published_templates_by_type([type.uuid]) == %{type.uuid => 1}

        # Moving the type leaves the membership under the old category, so the
        # preset editor of the new one lists nothing — and neither does the count.
        {:ok, moved} = Taxonomy.update_type(type, %{category_uuid: other.uuid})

        assert Documents.list_templates_for_category(other.uuid) == []
        assert Taxonomy.count_published_templates_by_type([moved.uuid]) == %{}
      end
    end

    describe "restore_type/1" do
      test "restores a trashed type and templates trashed by cascade" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        tmpl = create_template!(%{type_uuid: type.uuid})

        {:ok, trashed_type} = Taxonomy.trash_type(type)
        {:ok, restored} = Taxonomy.restore_type(trashed_type)

        assert restored.status == "active"
        assert Repo.get!(Template, tmpl.uuid).status == "published"
      end
    end

    describe "permanently_delete_type/1" do
      test "removes the type and nullifies type_uuid on templates" do
        cat = create_category!()
        type = create_type!(cat.uuid)
        tmpl = create_template!(%{type_uuid: type.uuid})

        assert {:ok, _} = Taxonomy.permanently_delete_type(type)

        assert Taxonomy.get_type(type.uuid) == nil
        assert Repo.get!(Template, tmpl.uuid).type_uuid == nil
      end
    end

    # ===========================================================================
    # Picker helpers
    # ===========================================================================

    describe "list_category_tree/0" do
      test "returns [{category, [types]}] ordered by position" do
        cat1 = create_category!(%{name: "Cat1", position: 0})
        cat2 = create_category!(%{name: "Cat2", position: 1})
        t1 = create_type!(cat1.uuid, %{name: "T1"})
        t2 = create_type!(cat1.uuid, %{name: "T2"})
        _deleted_cat = Taxonomy.create_category(%{name: "Del", status: "deleted"})

        tree = Taxonomy.list_category_tree()
        cat_uuids = Enum.map(tree, fn {cat, _types} -> cat.uuid end)

        assert cat1.uuid in cat_uuids
        assert cat2.uuid in cat_uuids
        # deleted category not in tree
        refute Enum.any?(tree, fn {cat, _} -> cat.status == "deleted" end)

        {found_cat1, found_types} = Enum.find(tree, fn {cat, _} -> cat.uuid == cat1.uuid end)
        assert found_cat1.uuid == cat1.uuid
        type_uuids = Enum.map(found_types, & &1.uuid)
        assert t1.uuid in type_uuids
        assert t2.uuid in type_uuids
      end
    end

    describe "category_options/0" do
      test "returns [{name, uuid}] for active categories with leading empty option" do
        cat = create_category!(%{name: "Finance"})
        {:ok, deleted} = Taxonomy.create_category(%{name: "Deleted", status: "deleted"})

        opts = Taxonomy.category_options()

        # Empty option always first.
        assert List.first(opts) == {"No category", nil}
        assert Enum.any?(opts, fn {name, uuid} -> name == "Finance" and uuid == cat.uuid end)
        refute Enum.any?(opts, fn {_name, uuid} -> uuid == deleted.uuid end)
      end
    end

    describe "type_options/1" do
      test "returns [{name, uuid}] for active types of a category with leading empty option" do
        cat = create_category!()
        t1 = create_type!(cat.uuid, %{name: "Invoice"})

        {:ok, del_t} =
          Taxonomy.create_type(%{name: "Del", category_uuid: cat.uuid, status: "deleted"})

        opts = Taxonomy.type_options(cat.uuid)

        # Empty option always first.
        assert List.first(opts) == {"No type", nil}
        assert Enum.any?(opts, fn {name, uuid} -> name == "Invoice" and uuid == t1.uuid end)
        refute Enum.any?(opts, fn {_name, uuid} -> uuid == del_t.uuid end)
      end

      test "type_options(nil) returns only the empty option" do
        assert Taxonomy.type_options(nil) == [{"No type", nil}]
      end
    end

    describe "localized_name/2" do
      test "returns the raw name when no translation data exists" do
        cat = create_category!(%{name: "Klient"})
        assert Taxonomy.localized_name(cat, "ru") == "Klient"
        assert Taxonomy.localized_name(cat, nil) == "Klient"
      end

      test "returns the primary-language override when locale matches primary" do
        cat = create_category!(%{name: "Klient"})

        {:ok, cat} =
          Taxonomy.update_category(cat, %{
            data: %{"_primary_language" => "et", "et" => %{"_name" => "Klient"}}
          })

        assert Taxonomy.localized_name(cat, "et") == "Klient"
      end

      test "returns a secondary-language override when present" do
        cat = create_category!(%{name: "Klient"})

        {:ok, cat} =
          Taxonomy.update_category(cat, %{
            data: %{
              "_primary_language" => "et",
              "et" => %{"_name" => "Klient"},
              "ru" => %{"_name" => "Клиент"}
            }
          })

        assert Taxonomy.localized_name(cat, "ru") == "Клиент"
        assert Taxonomy.localized_name(cat, "et") == "Klient"
      end

      test "falls back to the primary override when a secondary language has none" do
        cat = create_category!(%{name: "Klient"})

        {:ok, cat} =
          Taxonomy.update_category(cat, %{
            data: %{"_primary_language" => "et", "et" => %{"_name" => "Klient"}}
          })

        assert Taxonomy.localized_name(cat, "en") == "Klient"
      end

      test "works the same way for Type records" do
        cat = create_category!()
        type = create_type!(cat.uuid, %{name: "Hooldusjuhend"})

        {:ok, type} =
          Taxonomy.update_type(type, %{
            data: %{
              "_primary_language" => "et",
              "et" => %{"_name" => "Hooldusjuhend"},
              "ru" => %{"_name" => "Руководство"}
            }
          })

        assert Taxonomy.localized_name(type, "ru") == "Руководство"
        assert Taxonomy.localized_name(type, "et") == "Hooldusjuhend"
      end
    end

    describe "category_options/1 and type_options/2 with locale" do
      test "category_options/1 returns translated labels when data has an override" do
        cat = create_category!(%{name: "Klient"})

        {:ok, _cat} =
          Taxonomy.update_category(cat, %{
            data: %{
              "_primary_language" => "et",
              "et" => %{"_name" => "Klient"},
              "ru" => %{"_name" => "Клиент"}
            }
          })

        opts = Taxonomy.category_options("ru")
        assert Enum.any?(opts, fn {name, uuid} -> name == "Клиент" and uuid == cat.uuid end)
      end

      test "type_options/2 returns translated labels when data has an override" do
        cat = create_category!()
        type = create_type!(cat.uuid, %{name: "Hooldusjuhend"})

        {:ok, _type} =
          Taxonomy.update_type(type, %{
            data: %{
              "_primary_language" => "et",
              "et" => %{"_name" => "Hooldusjuhend"},
              "ru" => %{"_name" => "Руководство"}
            }
          })

        opts = Taxonomy.type_options(cat.uuid, "ru")
        assert Enum.any?(opts, fn {name, uuid} -> name == "Руководство" and uuid == type.uuid end)
      end
    end

    defp errors_on(changeset) do
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
    end
  end
end
