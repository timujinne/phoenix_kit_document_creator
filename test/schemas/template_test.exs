defmodule PhoenixKitDocumentCreator.Schemas.TemplateTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.Template

  @valid_attrs %{name: "Service Agreement"}

  defp changeset(attrs) do
    Template.changeset(%Template{}, attrs)
  end

  describe "changeset/2 with valid data" do
    test "is valid with only required fields" do
      cs = changeset(@valid_attrs)
      assert cs.valid?
    end

    test "accepts optional content fields" do
      cs =
        changeset(%{
          name: "Template",
          content_html: "<p>Hello {{ name }}</p>",
          content_css: "p { margin: 0; }",
          content_native: %{"pages" => []}
        })

      assert cs.valid?
    end

    test "accepts variables list" do
      cs =
        changeset(%{
          name: "Template",
          variables: [%{"name" => "client", "type" => "text"}]
        })

      assert cs.valid?
    end

    test "accepts description" do
      cs = changeset(%{name: "Tmpl", description: "A test template"})
      assert cs.valid?
    end

    test "accepts header_uuid and footer_uuid" do
      h_uuid = Ecto.UUID.generate()
      f_uuid = Ecto.UUID.generate()
      cs = changeset(%{name: "Tmpl", header_uuid: h_uuid, footer_uuid: f_uuid})
      assert cs.valid?
    end
  end

  describe "changeset/2 with invalid data" do
    test "is invalid without name" do
      cs = changeset(%{})
      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "is invalid with empty string name" do
      cs = changeset(%{name: ""})
      refute cs.valid?
    end

    test "is invalid with name exceeding 255 characters" do
      cs = changeset(%{name: String.duplicate("x", 256)})
      refute cs.valid?
    end

    test "name at exactly 255 characters is valid" do
      cs = changeset(%{name: String.duplicate("x", 255)})
      assert cs.valid?
    end
  end

  describe "status validation" do
    test "accepts 'published' status" do
      cs = changeset(%{name: "Tmpl", status: "published"})
      assert cs.valid?
    end

    test "accepts 'trashed' status" do
      cs = changeset(%{name: "Tmpl", status: "trashed"})
      assert cs.valid?
    end

    test "rejects invalid status" do
      cs = changeset(%{name: "Tmpl", status: "archived"})
      refute cs.valid?
      assert %{status: [_]} = errors_on(cs)
    end

    test "empty string status is accepted (cast as no change)" do
      cs = changeset(%{name: "Tmpl", status: ""})
      # Empty string is cast but the default "published" applies
      assert cs.valid?
    end
  end

  describe "slug auto-generation" do
    test "generates slug from name when slug is not provided" do
      cs = changeset(%{name: "My Great Template"})
      assert Ecto.Changeset.get_change(cs, :slug) == "my-great-template"
    end

    test "preserves explicit slug when provided" do
      cs = changeset(%{name: "My Template", slug: "custom-slug"})
      assert Ecto.Changeset.get_change(cs, :slug) == "custom-slug"
    end

    test "slugifies by lowercasing and replacing spaces with hyphens" do
      cs = changeset(%{name: "Hello World"})
      assert Ecto.Changeset.get_change(cs, :slug) == "hello-world"
    end

    test "strips special characters from slug" do
      cs = changeset(%{name: "Invoice (Q1) #2024!"})
      slug = Ecto.Changeset.get_change(cs, :slug)
      refute String.contains?(slug, "(")
      refute String.contains?(slug, ")")
      refute String.contains?(slug, "#")
      refute String.contains?(slug, "!")
    end

    test "collapses multiple hyphens into one" do
      cs = changeset(%{name: "foo  --  bar"})
      slug = Ecto.Changeset.get_change(cs, :slug)
      refute String.contains?(slug, "--")
    end

    test "trims leading and trailing hyphens" do
      cs = changeset(%{name: " - test - "})
      slug = Ecto.Changeset.get_change(cs, :slug)
      refute String.starts_with?(slug, "-")
      refute String.ends_with?(slug, "-")
    end

    test "does not generate slug when name is unchanged (update without name change)" do
      # Simulating an update where name is not changed
      existing = %Template{name: "Existing", slug: "existing"}
      cs = Template.changeset(existing, %{description: "Updated description"})
      assert cs.valid?
      # slug should not be regenerated
      assert Ecto.Changeset.get_change(cs, :slug) == nil
    end

    test "slug max length is 255" do
      cs = changeset(%{name: "Test", slug: String.duplicate("a", 256)})
      refute cs.valid?
    end
  end

  describe "schema defaults" do
    test "default field values on struct" do
      tmpl = %Template{}
      assert tmpl.content_html == ""
      assert tmpl.content_css == ""
      assert tmpl.status == "published"
      assert tmpl.variables == []
      assert tmpl.config == %{"paper_size" => "a4", "orientation" => "portrait"}
      assert tmpl.data == %{}
    end
  end

  describe "sync_changeset/2" do
    test "is valid with required fields" do
      cs = Template.sync_changeset(%Template{}, %{name: "T", google_doc_id: "abc"})
      assert cs.valid?
    end

    test "rejects name longer than 255 chars (clean error vs Postgres exception)" do
      cs =
        Template.sync_changeset(%Template{}, %{
          name: String.duplicate("X", 256),
          google_doc_id: "abc"
        })

      refute cs.valid?
      assert %{name: ["should be at most 255 character(s)"]} = errors_on(cs)
    end

    test "accepts Unicode in name" do
      cs =
        Template.sync_changeset(%Template{}, %{
          name: "Café 報告",
          google_doc_id: "abc"
        })

      assert cs.valid?
    end

    test "does NOT cast :language — user-set values survive Drive sync" do
      # `sync_changeset/2` deliberately omits :language from its cast
      # allowlist so an admin's locale choice isn't clobbered by the
      # next walker pass (which only carries Drive-provided fields).
      cs =
        Template.sync_changeset(
          %Template{language: "et-EE"},
          %{name: "T", google_doc_id: "abc", language: "ja"}
        )

      assert cs.valid?
      # Language change is dropped on the floor — old value retained.
      refute Map.has_key?(cs.changes, :language)
    end
  end

  describe "language field (V110)" do
    test "accepts a full locale code via changeset/2" do
      cs = changeset(%{name: "T", language: "en-US"})
      assert cs.valid?
      assert cs.changes.language == "en-US"
    end

    test "accepts a base locale code (e.g. \"ja\")" do
      cs = changeset(%{name: "T", language: "ja"})
      assert cs.valid?
      assert cs.changes.language == "ja"
    end

    test "accepts nil (clearing the language)" do
      cs = changeset(%{name: "T", language: nil})
      assert cs.valid?
    end

    test "accepts empty string (cast to nil for string fields per Ecto default)" do
      cs = changeset(%{name: "T", language: ""})
      assert cs.valid?
    end

    test "rejects language longer than 10 chars (matches V110 column size)" do
      cs = changeset(%{name: "T", language: String.duplicate("x", 11)})
      refute cs.valid?
      assert %{language: ["should be at most 10 character(s)"]} = errors_on(cs)
    end

    test "language at exactly 10 chars is valid (boundary)" do
      cs = changeset(%{name: "T", language: String.duplicate("x", 10)})
      assert cs.valid?
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
