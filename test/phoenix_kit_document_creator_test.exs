defmodule PhoenixKitDocumentCreatorTest do
  use ExUnit.Case

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitDocumentCreator.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitDocumentCreator.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns correct key" do
      assert PhoenixKitDocumentCreator.module_key() == "document_creator"
    end

    test "module_name/0 returns correct name" do
      assert PhoenixKitDocumentCreator.module_name() == "Document Creator"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitDocumentCreator.enabled?())
    end

    test "enable_system/0 is exported" do
      assert function_exported?(PhoenixKitDocumentCreator, :enable_system, 0)
    end

    test "disable_system/0 is exported" do
      assert function_exported?(PhoenixKitDocumentCreator, :disable_system, 0)
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitDocumentCreator.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitDocumentCreator.permission_metadata()
      assert meta.key == PhoenixKitDocumentCreator.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitDocumentCreator.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns 3 tabs (parent + documents + templates)" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()
      assert is_list(tabs)
      assert length(tabs) == 3
    end

    test "parent tab has correct fields" do
      [parent | _] = PhoenixKitDocumentCreator.admin_tabs()
      assert parent.id == :admin_document_creator
      assert parent.label == "Document Creator"
      assert parent.level == :admin
      assert parent.permission == PhoenixKitDocumentCreator.module_key()
      assert parent.group == :admin_modules
    end

    test "parent tab routes to DocumentsLive :documents" do
      [parent | _] = PhoenixKitDocumentCreator.admin_tabs()
      assert {PhoenixKitDocumentCreator.Web.DocumentsLive, :documents} = parent.live_view
    end

    test "subtabs reference parent" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()
      [_parent | subtabs] = tabs

      for subtab <- subtabs do
        assert subtab.parent == :admin_document_creator,
               "Tab #{subtab.id} references unknown parent #{subtab.parent}"
      end
    end

    test "includes documents and templates subtabs" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.DocumentsLive, :documents}, tab.live_view) and
                 tab.id == :admin_document_creator_documents
             end)

      assert Enum.any?(tabs, fn tab ->
               match?({PhoenixKitDocumentCreator.Web.DocumentsLive, :templates}, tab.live_view) and
                 tab.id == :admin_document_creator_templates
             end)
    end

    test "paths use hyphens not underscores (except route params)" do
      tabs = PhoenixKitDocumentCreator.admin_tabs()

      for tab <- tabs do
        path_without_params = Regex.replace(~r/:[a-z_]+/, tab.path, "")

        refute String.contains?(path_without_params, "_"),
               "Tab #{tab.id} path #{tab.path} contains underscores"
      end
    end
  end

  describe "required_integrations/0" do
    test "declares google as required" do
      assert PhoenixKitDocumentCreator.required_integrations() == ["google"]
    end
  end

  describe "version/0" do
    test "returns the mix.exs declared version" do
      # Derived from `Mix.Project.config()[:version]` at compile time —
      # the runtime value can't drift from `@version` in mix.exs.
      version = PhoenixKitDocumentCreator.version()
      assert is_binary(version)
      assert version == Mix.Project.config()[:version]
    end
  end

  describe "Variable" do
    alias PhoenixKitDocumentCreator.Variable

    test "extract_variables/1 finds template variables" do
      fork = Variable.extract_variables("Hello {{ name }}, total: {{ amount }}")
      assert "amount" in fork.text
      assert "name" in fork.text
    end

    test "extract_variables/1 returns empty maps for nil" do
      assert Variable.extract_variables(nil) == %{text: [], image: []}
    end

    test "build_definitions/1 creates Variable structs" do
      defs = Variable.build_definitions(%{text: ["company", "contract_date"], image: []})
      assert length(defs) == 2
      assert %Variable{name: "company", label: "Company", type: :text} = hd(defs)
    end

    test "guess_type/1 detects date, currency, multiline" do
      assert Variable.guess_type("contract_date") == :date
      assert Variable.guess_type("total_amount") == :currency
      assert Variable.guess_type("description") == :multiline
      assert Variable.guess_type("company") == :text
    end

    test "humanize/1 converts underscore names" do
      assert Variable.humanize("client_name") == "Client Name"
      assert Variable.humanize("amount") == "Amount"
    end

    # ── Edge cases on Variable helpers ──────────────────────────────

    test "extract_variables/1 deduplicates repeated names" do
      fork = Variable.extract_variables("Hi {{ name }}, again {{ name }}, and {{ name }}.")
      assert fork.text == ["name"]
    end

    test "extract_variables/1 ignores malformed placeholders" do
      # Single brace, missing closing, hyphenated names (\w doesn't match `-`).
      assert Variable.extract_variables("{ name }") == %{text: [], image: []}
      assert Variable.extract_variables("{{ name") == %{text: [], image: []}
      assert Variable.extract_variables("{{ first-name }}") == %{text: [], image: []}
    end

    test "extract_variables/1 with non-ASCII content does not crash" do
      # `\w` is ASCII-only in Erlang regex so Unicode identifiers like
      # `{{ имя }}` or `{{ 名前 }}` aren't picked up. Pinning current
      # behaviour so a future regex tightening doesn't silently regress
      # ASCII parsing.
      assert Variable.extract_variables("{{ имя }} and {{ name }} together").text == ["name"]
      assert Variable.extract_variables("{{ 名前 }}") == %{text: [], image: []}
    end

    test "extract_variables/1 returns empty fork for non-binary input" do
      assert Variable.extract_variables(:atom) == %{text: [], image: []}
      assert Variable.extract_variables(123) == %{text: [], image: []}
      assert Variable.extract_variables(%{}) == %{text: [], image: []}
    end

    test "extract_variables/1 handles very long input" do
      long_text = String.duplicate("filler ", 5_000) <> "{{ marker }}"
      assert Variable.extract_variables(long_text).text == ["marker"]
    end

    test "humanize/1 capitalises Unicode-leading words correctly" do
      # `String.capitalize/1` is acceptable here because Variable names
      # are programmatic identifiers (extracted from regex), not user-
      # facing translated text. Pinning that the function doesn't crash
      # on Unicode content even though the extractor wouldn't usually
      # produce it.
      assert Variable.humanize("café_total") == "Café Total"
      assert Variable.humanize("") == ""
    end

    test "build_definitions/1 accepts empty fork" do
      assert Variable.build_definitions(%{text: [], image: []}) == []
    end
  end
end
