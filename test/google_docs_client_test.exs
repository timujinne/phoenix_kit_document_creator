defmodule PhoenixKitDocumentCreator.GoogleDocsClientTest do
  # `async: false` because the SSRF redirect-block describe below sets
  # `Application.put_env(..., :req_options, ...)`. Application env is
  # global state and would race against other test modules running
  # concurrently. The unit assertions here are fast either way.
  use ExUnit.Case, async: false

  alias PhoenixKitDocumentCreator.GoogleDocsClient

  describe "module interface" do
    test "module compiles and is loaded" do
      assert Code.ensure_loaded?(GoogleDocsClient)
    end

    test "exports credential functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:get_credentials, 0} in exports
      assert {:connection_status, 0} in exports
      assert {:folder_settings_key, 0} in exports
    end

    test "exports folder functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:find_folder_by_name, 1} in exports
      assert {:find_folder_by_name, 2} in exports
      assert {:create_folder, 1} in exports
      assert {:create_folder, 2} in exports
      assert {:find_or_create_folder, 1} in exports
      assert {:find_or_create_folder, 2} in exports
      assert {:ensure_folder_path, 1} in exports
      assert {:ensure_folder_path, 2} in exports
      assert {:discover_folders, 0} in exports
      assert {:get_folder_ids, 0} in exports
      assert {:get_folder_url, 1} in exports
      assert {:get_folder_config, 0} in exports
      assert {:list_subfolders, 0} in exports
      assert {:list_subfolders, 1} in exports
    end

    test "exports document functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:create_document, 1} in exports
      assert {:create_document, 2} in exports
      assert {:get_document, 1} in exports
      assert {:batch_update, 2} in exports
      assert {:replace_all_text, 2} in exports
      assert {:get_document_text, 1} in exports
    end

    test "exports Drive functions" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:move_file, 2} in exports
      assert {:copy_file, 2} in exports
      assert {:copy_file, 3} in exports
      assert {:export_pdf, 1} in exports
      assert {:fetch_thumbnail, 1} in exports
      assert {:list_folder_files, 1} in exports
      assert {:validate_file_id, 1} in exports
    end

    test "exports get_folder_config/0 and resolved_folder_paths/1" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:get_folder_config, 0} in exports
      assert {:resolved_folder_paths, 1} in exports
    end

    test "exports migrate_folders_to_root/1" do
      exports = GoogleDocsClient.__info__(:functions)
      assert {:migrate_folders_to_root, 1} in exports
    end
  end

  describe "get_edit_url/1" do
    test "returns a Google Docs URL for valid doc ID" do
      url = GoogleDocsClient.get_edit_url("abc123")
      assert url == "https://docs.google.com/document/d/abc123/edit"
    end

    test "returns nil for nil" do
      assert GoogleDocsClient.get_edit_url(nil) == nil
    end

    test "returns nil for empty string" do
      assert GoogleDocsClient.get_edit_url("") == nil
    end
  end

  describe "get_folder_url/1" do
    test "returns a Drive folder URL for valid folder ID" do
      url = GoogleDocsClient.get_folder_url("folder123")
      assert url == "https://drive.google.com/drive/folders/folder123"
    end

    test "returns nil for nil" do
      assert GoogleDocsClient.get_folder_url(nil) == nil
    end

    test "returns nil for empty string" do
      assert GoogleDocsClient.get_folder_url("") == nil
    end
  end

  describe "list_folder_files/1" do
    test "returns {:ok, []} for nil folder ID" do
      assert GoogleDocsClient.list_folder_files(nil) == {:ok, []}
    end

    test "returns {:ok, []} for empty folder ID" do
      assert GoogleDocsClient.list_folder_files("") == {:ok, []}
    end
  end

  describe "DriveWalker" do
    alias PhoenixKitDocumentCreator.GoogleDocsClient.DriveWalker

    test "list_files returns {:ok, []} for nil" do
      assert DriveWalker.list_files(nil) == {:ok, []}
    end

    test "list_files returns {:ok, []} for empty string" do
      assert DriveWalker.list_files("") == {:ok, []}
    end

    test "list_folders returns {:ok, []} for nil" do
      assert DriveWalker.list_folders(nil) == {:ok, []}
    end

    test "list_folders returns {:ok, []} for empty string" do
      assert DriveWalker.list_folders("") == {:ok, []}
    end

    test "exports walk_tree/2" do
      exports = DriveWalker.__info__(:functions)
      assert {:walk_tree, 1} in exports
      assert {:walk_tree, 2} in exports
    end
  end

  describe "fetch_thumbnail/1" do
    test "returns {:error, :no_doc_id} for nil" do
      assert GoogleDocsClient.fetch_thumbnail(nil) == {:error, :no_doc_id}
    end

    test "returns {:error, :no_doc_id} for empty string" do
      assert GoogleDocsClient.fetch_thumbnail("") == {:error, :no_doc_id}
    end
  end

  describe "validate_thumbnail_url/1 (SSRF guard)" do
    # Pin the allowlist of host suffixes the SSRF guard accepts. The
    # `thumbnailLink` URL comes from Drive but a poisoned response /
    # MITM could substitute a metadata-service or internal-IP URL —
    # without this guard, `fetch_thumbnail_image/1` would call out to
    # whatever Drive returned, exposing internal services.

    test "accepts standard Google thumbnail CDN URLs" do
      assert :ok =
               GoogleDocsClient.validate_thumbnail_url(
                 "https://lh3.googleusercontent.com/abc/=s220"
               )

      assert :ok =
               GoogleDocsClient.validate_thumbnail_url("https://lh4.googleusercontent.com/foo")

      assert :ok =
               GoogleDocsClient.validate_thumbnail_url("https://docs.google.com/uc?id=abc")
    end

    test "rejects cloud-metadata service" do
      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("http://169.254.169.254/latest/meta-data/")
    end

    test "rejects localhost / loopback" do
      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("http://localhost:8080/admin")

      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("http://127.0.0.1/")
    end

    test "rejects private IP ranges" do
      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("http://10.0.0.1/")

      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("http://192.168.1.1/")

      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("http://172.16.0.1/")
    end

    test "rejects look-alike hosts that don't end on the allowed suffix" do
      # "googleusercontent.com.evil.com" must not pass — String.ends_with?
      # on the FULL host comparing the suffix rules out this trick.
      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url(
                 "https://googleusercontent.com.evil.com/abc"
               )

      assert {:error, :host_not_allowed} =
               GoogleDocsClient.validate_thumbnail_url("https://my-googleusercontent.com/abc")
    end

    test "rejects non-HTTP schemes" do
      assert {:error, :invalid_url} =
               GoogleDocsClient.validate_thumbnail_url("file:///etc/passwd")

      assert {:error, :invalid_url} =
               GoogleDocsClient.validate_thumbnail_url("javascript:alert(1)")
    end

    test "rejects malformed URLs and non-strings" do
      assert {:error, :invalid_url} = GoogleDocsClient.validate_thumbnail_url("")
      assert {:error, :invalid_url} = GoogleDocsClient.validate_thumbnail_url(nil)
      assert {:error, :invalid_url} = GoogleDocsClient.validate_thumbnail_url(:not_a_url)
    end
  end

  describe "fetch_thumbnail_image/1 (SSRF redirect block)" do
    # Pin the second-pass guard: even when the input URL passes the
    # allowlist, Req must NOT follow a 302 to an internal host (e.g.
    # 169.254.169.254). Req `~> 0.5` follows redirects by default; the
    # `redirect: false` opt is what closes this off.
    setup do
      stub_name = String.to_atom("ThumbStub-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_document_creator, :req_options)
      end)

      Application.put_env(:phoenix_kit_document_creator, :req_options,
        plug: {Req.Test, stub_name}
      )

      {:ok, stub: stub_name}
    end

    test "does not follow a 302 to an internal host", %{stub: stub_name} do
      test_pid = self()

      Req.Test.stub(stub_name, fn conn ->
        send(test_pid, {:plug_called, conn.host})

        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
        |> Plug.Conn.send_resp(302, "")
      end)

      # Allowed input URL — passes the host allowlist. The 302 response
      # would steer Req to the metadata service if redirect-following
      # were enabled.
      assert {:error, :thumbnail_fetch_failed} =
               GoogleDocsClient.fetch_thumbnail_image("https://lh3.googleusercontent.com/abc")

      # Plug is hit exactly once — Req did not chase the redirect.
      assert_receive {:plug_called, "lh3.googleusercontent.com"}
      refute_receive {:plug_called, "169.254.169.254"}, 50
    end

    test "rejects an input URL outside the allowlist before issuing any request" do
      # Sanity check: the URL guard fires first, no Req call attempted.
      assert {:error, :thumbnail_fetch_failed} =
               GoogleDocsClient.fetch_thumbnail_image("http://169.254.169.254/foo")
    end
  end

  describe "replace_all_text/2" do
    test "returns {:ok, %{}} for empty variables map" do
      assert GoogleDocsClient.replace_all_text("any_doc_id", %{}) == {:ok, %{}}
    end
  end

  describe "validate_file_id/1" do
    test "accepts valid alphanumeric IDs" do
      assert {:ok, "abc123"} = GoogleDocsClient.validate_file_id("abc123")
    end

    test "accepts IDs with hyphens and underscores" do
      assert {:ok, "abc-123_XYZ"} = GoogleDocsClient.validate_file_id("abc-123_XYZ")
    end

    test "rejects IDs with slashes" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id("abc/123")
    end

    test "rejects IDs with query strings" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id("abc?q=1")
    end

    test "rejects empty string" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id("")
    end

    test "rejects nil" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.validate_file_id(nil)
    end
  end

  describe "move_file/2" do
    test "rejects invalid file ID" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.move_file("../etc/passwd", "folder123")
    end

    test "rejects invalid folder ID" do
      assert {:error, :invalid_file_id} = GoogleDocsClient.move_file("file123", "folder/bad")
    end
  end

  describe "resolved_folder_paths/1" do
    test "no root: paths are unchanged" do
      config = %{
        root_path: "", root_name: "",
        templates_path: "", templates_name: "templates",
        documents_path: "clients", documents_name: "docs",
        deleted_path: "", deleted_name: "deleted"
      }

      {t, d, del} = GoogleDocsClient.resolved_folder_paths(config)

      assert t == "templates"
      assert d == "clients/docs"
      assert del == "deleted"
    end

    test "root set: all paths prefixed with root" do
      config = %{
        root_path: "", root_name: "my-project",
        templates_path: "", templates_name: "šabloonid",
        documents_path: "", documents_name: "dokumendid",
        deleted_path: "", deleted_name: "kustutatud"
      }

      {t, d, del} = GoogleDocsClient.resolved_folder_paths(config)

      assert t == "my-project/šabloonid"
      assert d == "my-project/dokumendid"
      assert del == "my-project/kustutatud"
    end

    test "root with path: root path prefixes root name" do
      config = %{
        root_path: "workspace", root_name: "project",
        templates_path: "", templates_name: "templates",
        documents_path: "", documents_name: "documents",
        deleted_path: "", deleted_name: "deleted"
      }

      {t, d, del} = GoogleDocsClient.resolved_folder_paths(config)

      assert t == "workspace/project/templates"
      assert d == "workspace/project/documents"
      assert del == "workspace/project/deleted"
    end
  end
end
