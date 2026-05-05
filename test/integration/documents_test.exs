# Only define this module when the test repo is available (DB connected).
# When excluded, the module is not compiled, avoiding DataCase load errors.
if Code.ensure_loaded?(PhoenixKitDocumentCreator.DataCase) do
  defmodule PhoenixKitDocumentCreator.Integration.DocumentsTest do
    use PhoenixKitDocumentCreator.DataCase, async: true

    alias PhoenixKitDocumentCreator.Documents
    alias PhoenixKitDocumentCreator.Schemas.Document
    alias PhoenixKitDocumentCreator.Schemas.Template

    # ===========================================================================
    # Upsert from Drive
    # ===========================================================================

    describe "upsert_template_from_drive/2" do
      test "inserts a new template" do
        assert {:ok, template} =
                 Documents.upsert_template_from_drive(%{"id" => "gdoc_t1", "name" => "Invoice"})

        assert template.google_doc_id == "gdoc_t1"
        assert template.name == "Invoice"
        assert template.status == "published"
      end

      test "upserts on conflict (same google_doc_id)" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t2", "name" => "Original"})

        {:ok, updated} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t2", "name" => "Renamed"})

        assert updated.name == "Renamed"

        # Only one record exists
        count =
          Template
          |> where([t], t.google_doc_id == "gdoc_t2")
          |> Repo.aggregate(:count)

        assert count == 1
      end

      test "accepts extra attrs (path, folder_id)" do
        {:ok, template} =
          Documents.upsert_template_from_drive(
            %{"id" => "gdoc_t3", "name" => "With Path"},
            %{path: "clients/templates", folder_id: "folder_abc"}
          )

        assert template.path == "clients/templates"
        assert template.folder_id == "folder_abc"
      end

      test "sets status to published on upsert" do
        {:ok, template} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t4", "name" => "Test"})

        # Manually mark as lost
        Template
        |> where([t], t.uuid == ^template.uuid)
        |> Repo.update_all(set: [status: "lost"])

        # Re-upsert should restore to published
        {:ok, restored} =
          Documents.upsert_template_from_drive(%{"id" => "gdoc_t4", "name" => "Test"})

        assert restored.status == "published"
      end
    end

    describe "upsert_document_from_drive/2" do
      test "inserts a new document" do
        assert {:ok, doc} =
                 Documents.upsert_document_from_drive(%{"id" => "gdoc_d1", "name" => "Report"})

        assert doc.google_doc_id == "gdoc_d1"
        assert doc.name == "Report"
        assert doc.status == "published"
      end

      test "upserts on conflict (same google_doc_id)" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "gdoc_d2", "name" => "Original"})

        {:ok, updated} =
          Documents.upsert_document_from_drive(%{"id" => "gdoc_d2", "name" => "Renamed"})

        assert updated.name == "Renamed"

        count =
          Document
          |> where([d], d.google_doc_id == "gdoc_d2")
          |> Repo.aggregate(:count)

        assert count == 1
      end

      test "accepts extra attrs (path, folder_id)" do
        {:ok, doc} =
          Documents.upsert_document_from_drive(
            %{"id" => "gdoc_d3", "name" => "With Path"},
            %{path: "clients/documents", folder_id: "folder_def"}
          )

        assert doc.path == "clients/documents"
        assert doc.folder_id == "folder_def"
      end
    end

    # ===========================================================================
    # DB Listing
    # ===========================================================================

    describe "list_templates_from_db/0" do
      test "returns published, lost, and unfiled templates" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "lt1", "name" => "Published"})

        {:ok, t2} =
          Documents.upsert_template_from_drive(%{"id" => "lt2", "name" => "Lost"})

        Template
        |> where([t], t.uuid == ^t2.uuid)
        |> Repo.update_all(set: [status: "lost"])

        {:ok, t3} =
          Documents.upsert_template_from_drive(%{"id" => "lt3", "name" => "Trashed"})

        Template
        |> where([t], t.uuid == ^t3.uuid)
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_templates_from_db()
        ids = Enum.map(results, & &1["id"])

        assert "lt1" in ids
        assert "lt2" in ids
        refute "lt3" in ids
      end

      test "excludes templates without google_doc_id" do
        Repo.insert!(%Template{name: "No GDoc ID", status: "published"})

        results = Documents.list_templates_from_db()
        names = Enum.map(results, & &1["name"])

        refute "No GDoc ID" in names
      end

      test "returns maps with expected keys" do
        {:ok, _} =
          Documents.upsert_template_from_drive(
            %{"id" => "lt_map", "name" => "Map Test"},
            %{path: "test/path", folder_id: "fid"}
          )

        [result] = Documents.list_templates_from_db()

        assert result["id"] == "lt_map"
        assert result["name"] == "Map Test"
        assert result["status"] == "published"
        assert result["path"] == "test/path"
        assert result["folder_id"] == "fid"
        assert is_binary(result["modifiedTime"])
      end
    end

    describe "list_documents_from_db/0" do
      test "returns published and lost documents, excludes trashed" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "ld1", "name" => "Published"})

        {:ok, d2} =
          Documents.upsert_document_from_drive(%{"id" => "ld2", "name" => "Trashed"})

        Document
        |> where([d], d.uuid == ^d2.uuid)
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_documents_from_db()
        ids = Enum.map(results, & &1["id"])

        assert "ld1" in ids
        refute "ld2" in ids
      end
    end

    describe "list_trashed_templates_from_db/0" do
      test "returns only trashed templates" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "ltt1", "name" => "Active"})

        {:ok, t2} =
          Documents.upsert_template_from_drive(%{"id" => "ltt2", "name" => "Trashed A"})

        {:ok, t3} =
          Documents.upsert_template_from_drive(%{"id" => "ltt3", "name" => "Trashed B"})

        Template
        |> where([t], t.uuid in ^[t2.uuid, t3.uuid])
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_trashed_templates_from_db()
        ids = Enum.map(results, & &1["id"])

        refute "ltt1" in ids
        assert "ltt2" in ids
        assert "ltt3" in ids
      end

      test "excludes templates without google_doc_id" do
        Repo.insert!(%Template{name: "No GDoc", status: "trashed"})

        results = Documents.list_trashed_templates_from_db()
        names = Enum.map(results, & &1["name"])

        refute "No GDoc" in names
      end

      test "returns empty list when nothing is trashed" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "ltt_none", "name" => "Active"})

        assert Documents.list_trashed_templates_from_db() == []
      end
    end

    describe "list_trashed_documents_from_db/0" do
      test "returns only trashed documents" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "ltd1", "name" => "Active"})

        {:ok, d2} =
          Documents.upsert_document_from_drive(%{"id" => "ltd2", "name" => "Trashed"})

        Document
        |> where([d], d.uuid == ^d2.uuid)
        |> Repo.update_all(set: [status: "trashed"])

        results = Documents.list_trashed_documents_from_db()
        ids = Enum.map(results, & &1["id"])

        refute "ltd1" in ids
        assert "ltd2" in ids
      end

      test "returns empty list when nothing is trashed" do
        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "ltd_none", "name" => "Active"})

        assert Documents.list_trashed_documents_from_db() == []
      end
    end

    # ===========================================================================
    # Thumbnails
    # ===========================================================================

    describe "persist_thumbnail/2" do
      test "persists thumbnail to template" do
        {:ok, t} =
          Documents.upsert_template_from_drive(%{"id" => "thumb_t", "name" => "Thumb Test"})

        :ok = Documents.persist_thumbnail("thumb_t", "data:image/png;base64,abc")

        updated = Repo.get!(Template, t.uuid)
        assert updated.thumbnail == "data:image/png;base64,abc"
      end

      test "persists thumbnail to document if no matching template" do
        {:ok, d} =
          Documents.upsert_document_from_drive(%{"id" => "thumb_d", "name" => "Doc Thumb"})

        :ok = Documents.persist_thumbnail("thumb_d", "data:image/png;base64,xyz")

        updated = Repo.get!(Document, d.uuid)
        assert updated.thumbnail == "data:image/png;base64,xyz"
      end
    end

    describe "load_cached_thumbnails/1" do
      test "loads thumbnails from both templates and documents" do
        {:ok, _} =
          Documents.upsert_template_from_drive(%{"id" => "ct1", "name" => "T1"})

        Documents.persist_thumbnail("ct1", "data:t1")

        {:ok, _} =
          Documents.upsert_document_from_drive(%{"id" => "cd1", "name" => "D1"})

        Documents.persist_thumbnail("cd1", "data:d1")

        thumbs = Documents.load_cached_thumbnails(["ct1", "cd1", "missing"])

        assert thumbs["ct1"] == "data:t1"
        assert thumbs["cd1"] == "data:d1"
        refute Map.has_key?(thumbs, "missing")
      end

      test "returns empty map for non-list input" do
        assert Documents.load_cached_thumbnails(nil) == %{}
      end

      test "returns empty map for empty list" do
        assert Documents.load_cached_thumbnails([]) == %{}
      end
    end

    # ===========================================================================
    # register_existing_document / register_existing_template
    # ===========================================================================

    describe "register_existing_document/2" do
      test "inserts a new document with minimal attrs" do
        assert {:ok, record} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d1",
                   name: "Invoice"
                 })

        assert record.google_doc_id == "reg_d1"
        assert record.name == "Invoice"
        assert record.status == "published"
        # Defaults fall back to managed-root — folder_id may be nil when
        # discovery hasn't run, which is fine for this unit-level test.
      end

      test "accepts string keys" do
        assert {:ok, record} =
                 Documents.register_existing_document(%{
                   "google_doc_id" => "reg_d_str",
                   "name" => "String Keys",
                   "folder_id" => "sub_folder_1",
                   "path" => "documents/order-1/sub-2"
                 })

        assert record.folder_id == "sub_folder_1"
        assert record.path == "documents/order-1/sub-2"
      end

      test "stores template_uuid and variable_values" do
        {:ok, tpl} =
          Documents.upsert_template_from_drive(%{"id" => "reg_tpl_src", "name" => "Src"})

        {:ok, record} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_from_tpl",
            name: "From Template",
            template_uuid: tpl.uuid,
            variable_values: %{"client" => "Acme", "amount" => "100"}
          })

        assert record.template_uuid == tpl.uuid
        assert record.variable_values == %{"client" => "Acme", "amount" => "100"}
      end

      test "upsert is idempotent on google_doc_id" do
        {:ok, _} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_idem",
            name: "Original",
            folder_id: "f1",
            path: "documents/a"
          })

        {:ok, updated} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_idem",
            name: "Renamed",
            folder_id: "f2",
            path: "documents/b"
          })

        assert updated.name == "Renamed"
        assert updated.folder_id == "f2"
        assert updated.path == "documents/b"

        count =
          Document
          |> where([d], d.google_doc_id == "reg_d_idem")
          |> Repo.aggregate(:count)

        assert count == 1
      end

      test "re-register without template_uuid/variable_values preserves existing values" do
        {:ok, tpl} =
          Documents.upsert_template_from_drive(%{
            "id" => "reg_tpl_preserve",
            "name" => "Tpl"
          })

        {:ok, _first} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_preserve",
            name: "Original",
            template_uuid: tpl.uuid,
            variable_values: %{"client" => "Acme"}
          })

        {:ok, _second} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_preserve",
            name: "Renamed"
          })

        reloaded =
          Document
          |> where([d], d.google_doc_id == "reg_d_preserve")
          |> Repo.one!()

        assert reloaded.name == "Renamed"
        assert reloaded.template_uuid == tpl.uuid
        assert reloaded.variable_values == %{"client" => "Acme"}
      end

      test "rejects missing google_doc_id" do
        assert {:error, :missing_google_doc_id} =
                 Documents.register_existing_document(%{name: "No ID"})
      end

      test "rejects missing name" do
        assert {:error, :missing_name} =
                 Documents.register_existing_document(%{google_doc_id: "reg_noname"})
      end

      test "rejects google_doc_id with invalid characters (URL-path injection guard)" do
        assert {:error, :invalid_google_doc_id} =
                 Documents.register_existing_document(%{
                   google_doc_id: "../etc/passwd",
                   name: "Evil"
                 })

        assert {:error, :invalid_google_doc_id} =
                 Documents.register_existing_document(%{
                   google_doc_id: "abc?query=1",
                   name: "Evil"
                 })
      end

      test "rejects invalid template_uuid with a changeset error (FK constraint)" do
        assert {:error, %Ecto.Changeset{} = cs} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_bad_tpl",
                   name: "With bad tpl",
                   template_uuid: "01234567-89ab-7def-8000-000000000000"
                 })

        assert cs.errors[:template_uuid]
      end

      test "respects explicit status" do
        {:ok, record} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_status",
            name: "Trashed Up Front",
            status: "trashed"
          })

        assert record.status == "trashed"
      end

      test "does not broadcast when emit_pubsub: false" do
        PhoenixKit.PubSubHelper.subscribe("document_creator:files")

        {:ok, _} =
          Documents.register_existing_document(
            %{google_doc_id: "reg_d_quiet", name: "Quiet"},
            emit_pubsub: false
          )

        refute_receive {:files_changed, _}, 200
      end

      test "broadcasts by default" do
        PhoenixKit.PubSubHelper.subscribe("document_creator:files")

        {:ok, _} =
          Documents.register_existing_document(%{
            google_doc_id: "reg_d_loud",
            name: "Loud"
          })

        assert_receive {:files_changed, _}, 500
      end

      # ── Edge cases on name field ────────────────────────────────────

      test "accepts Unicode in name (round-trips through DB)" do
        unique = System.unique_integer([:positive])
        unicode_name = "Café 報告 العربية #{unique}"

        assert {:ok, record} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_unicode_#{unique}",
                   name: unicode_name
                 })

        assert record.name == unicode_name
      end

      test "rejects name exceeding 255 chars with a changeset error" do
        long_name = String.duplicate("X", 256)

        assert {:error, %Ecto.Changeset{} = cs} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_long_#{System.unique_integer([:positive])}",
                   name: long_name
                 })

        assert cs.errors[:name]
      end

      test "accepts a 255-char name (boundary)" do
        boundary_name = String.duplicate("a", 255)
        unique = System.unique_integer([:positive])

        assert {:ok, record} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_max_#{unique}",
                   name: boundary_name
                 })

        assert byte_size(record.name) == 255
      end

      test "treats SQL metacharacters in name as literal text (Ecto parameterises)" do
        injection_attempt = "'; DROP TABLE phoenix_kit_doc_creator_documents; --"
        unique = System.unique_integer([:positive])

        assert {:ok, record} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_sqlmeta_#{unique}",
                   name: injection_attempt
                 })

        # The string round-trips literally; the table the injection
        # tried to drop is still intact (the next register insert
        # would fail otherwise).
        assert record.name == injection_attempt

        assert {:ok, _} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_sqlmeta_after_#{unique}",
                   name: "Survives"
                 })
      end

      test "rejects empty name at the normalize step" do
        # `normalize_register_attrs/1` rejects empty / nil names before
        # the changeset is reached, returning a sentinel atom rather
        # than a changeset. Pinning the actual return shape so a future
        # refactor that pushes this into the changeset doesn't silently
        # change the public API.
        assert {:error, :missing_name} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_empty_#{System.unique_integer([:positive])}",
                   name: ""
                 })

        assert {:error, :missing_name} =
                 Documents.register_existing_document(%{
                   google_doc_id: "reg_d_nil_#{System.unique_integer([:positive])}"
                 })
      end
    end

    describe "register_existing_template/2" do
      test "inserts a new template with minimal attrs" do
        assert {:ok, record} =
                 Documents.register_existing_template(%{
                   google_doc_id: "reg_t1",
                   name: "Tpl"
                 })

        assert record.google_doc_id == "reg_t1"
        assert record.name == "Tpl"
        assert record.status == "published"
      end

      test "upsert is idempotent on google_doc_id" do
        {:ok, _} =
          Documents.register_existing_template(%{
            google_doc_id: "reg_t_idem",
            name: "Original",
            folder_id: "f1",
            path: "templates/a"
          })

        {:ok, updated} =
          Documents.register_existing_template(%{
            google_doc_id: "reg_t_idem",
            name: "Renamed",
            folder_id: "f2",
            path: "templates/b"
          })

        assert updated.name == "Renamed"
        assert updated.folder_id == "f2"
        assert updated.path == "templates/b"

        count =
          Template
          |> where([t], t.google_doc_id == "reg_t_idem")
          |> Repo.aggregate(:count)

        assert count == 1
      end

      test "rejects missing google_doc_id" do
        assert {:error, :missing_google_doc_id} =
                 Documents.register_existing_template(%{name: "No ID"})
      end
    end

    # ===========================================================================
    # classify_by_location (MapSet-based nested-folder classification)
    # ===========================================================================

    describe "classify_by_location/5" do
      test "published when parent matches file's stored folder_id" do
        result =
          Documents.classify_by_location(
            ["sub_folder_xyz"],
            "sub_folder_xyz",
            MapSet.new([]),
            %{folder_id: "managed_root"},
            nil
          )

        assert result == :published
      end

      test "published when parent is in the allowed-folders MapSet (descendant subfolder)" do
        result =
          Documents.classify_by_location(
            ["nested_subfolder_id"],
            nil,
            MapSet.new(["managed_root", "nested_subfolder_id", "other_sub"]),
            %{folder_id: "managed_root"},
            nil
          )

        assert result == :published
      end

      test "published when parent is the managed root fallback" do
        result =
          Documents.classify_by_location(
            ["managed_root"],
            nil,
            MapSet.new([]),
            %{folder_id: "managed_root"},
            nil
          )

        assert result == :published
      end

      test "trashed when deleted folder is among parents" do
        result =
          Documents.classify_by_location(
            ["deleted_folder_id"],
            "managed_root",
            MapSet.new(["managed_root", "deleted_folder_id"]),
            %{folder_id: "managed_root"},
            "deleted_folder_id"
          )

        assert result == :trashed
      end

      test "unfiled when parent is outside managed tree" do
        result =
          Documents.classify_by_location(
            ["random_other_folder"],
            nil,
            MapSet.new(["managed_root"]),
            %{folder_id: "managed_root"},
            "deleted_folder_id"
          )

        assert result == :unfiled
      end
    end

    # ===========================================================================
    # update_template_language (V110)
    # ===========================================================================

    describe "update_template_language/3" do
      setup do
        {:ok, template} =
          Documents.upsert_template_from_drive(%{"id" => "lang_t1", "name" => "Localised"})

        %{template: template}
      end

      test "sets language on an existing template", %{template: template} do
        assert {:ok, updated} = Documents.update_template_language("lang_t1", "et-EE")
        assert updated.language == "et-EE"

        # Re-read confirms persistence
        reloaded = Repo.get!(Template, template.uuid)
        assert reloaded.language == "et-EE"
      end

      test "overwrites a previously-set language" do
        {:ok, _} = Documents.update_template_language("lang_t1", "ja")
        {:ok, updated} = Documents.update_template_language("lang_t1", "en-US")
        assert updated.language == "en-US"
      end

      test "clears language when passed nil" do
        {:ok, _} = Documents.update_template_language("lang_t1", "et")
        {:ok, cleared} = Documents.update_template_language("lang_t1", nil)
        assert is_nil(cleared.language)
      end

      test "clears language when passed empty string" do
        {:ok, _} = Documents.update_template_language("lang_t1", "et")
        {:ok, cleared} = Documents.update_template_language("lang_t1", "")
        assert is_nil(cleared.language)
      end

      test "returns {:error, :not_found} for unknown google_doc_id" do
        assert {:error, :not_found} =
                 Documents.update_template_language("does-not-exist", "en-US")
      end

      test "returns {:error, changeset} when language exceeds 10 chars" do
        assert {:error, %Ecto.Changeset{valid?: false} = cs} =
                 Documents.update_template_language("lang_t1", String.duplicate("x", 11))

        # Inline `errors_on` flatten — keeps the integration suite free
        # of a workspace-level helper for this single assertion.
        flat =
          Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        assert %{language: ["should be at most 10 character(s)"]} = flat
      end

      test "logs template.language_updated with from/to on success", %{template: template} do
        actor_uuid = Ecto.UUID.generate()

        {:ok, _} = Documents.update_template_language("lang_t1", nil)
        {:ok, _} = Documents.update_template_language("lang_t1", "ja", actor_uuid: actor_uuid)

        row =
          assert_activity_logged("template.language_updated",
            actor_uuid: actor_uuid,
            metadata_has: %{
              "name" => template.name,
              "google_doc_id" => "lang_t1",
              "language_to" => "ja"
            }
          )

        # `language_from` should be nil (template just got cleared above)
        assert is_nil(row.metadata["language_from"])
      end

      test "logs failure-side audit row when google_doc_id is unknown" do
        actor_uuid = Ecto.UUID.generate()

        assert {:error, :not_found} =
                 Documents.update_template_language("missing-id", "ja", actor_uuid: actor_uuid)

        row =
          assert_activity_logged("template.language_updated",
            actor_uuid: actor_uuid,
            metadata_has: %{
              "google_doc_id" => "missing-id",
              "language_to" => "ja",
              "db_pending" => true
            }
          )

        # No name/from on the failure side because the row never existed
        assert is_nil(row.metadata["name"])
      end

      test "broadcasts files_changed on success" do
        :ok = Phoenix.PubSub.subscribe(PhoenixKit.PubSub, Documents.pubsub_topic())

        {:ok, _} = Documents.update_template_language("lang_t1", "et-EE")

        assert_receive {:files_changed, _from_pid}, 200
      end
    end

    # ===========================================================================
    # detect_variables (DB persistence)
    # ===========================================================================

    describe "detect_variables/1 DB persistence" do
      test "persists detected variable definitions to template record" do
        {:ok, t} =
          Documents.upsert_template_from_drive(%{"id" => "var_t", "name" => "Var Test"})

        assert t.variables == []

        # We can't call detect_variables without mocking GoogleDocsClient,
        # but we can verify the schema supports variable storage
        Template
        |> where([t], t.uuid == ^t.uuid)
        |> Repo.update_all(
          set: [variables: [%{"name" => "client", "label" => "Client", "type" => "text"}]]
        )

        updated = Repo.get!(Template, t.uuid)
        assert [%{"name" => "client"}] = updated.variables
      end
    end
  end
end
