defmodule PhoenixKitDocumentCreator.PathsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Paths

  describe "path helpers" do
    test "index/0 returns the admin index path" do
      assert is_binary(Paths.index())
      assert Paths.index() =~ "/admin/document-creator"
    end

    test "templates/0 returns the templates subpath" do
      assert Paths.templates() =~ "/admin/document-creator/templates"
    end

    test "documents/0 returns the documents subpath" do
      assert Paths.documents() =~ "/admin/document-creator/documents"
    end

    test "settings/0 returns the settings subpath" do
      assert Paths.settings() =~ "/admin/settings/document-creator"
    end

    test "integrations/0 and new_integration/0 point at core's WEBSITE-wide pages" do
      # Not `/profile/settings/integrations`: that page stores connections under
      # a `{:user, uuid}` owner, which this module never passes, so a person
      # following the link would land somewhere that cannot show the connection
      # the picker just listed.
      assert Paths.integrations() =~ "/admin/settings/integrations"
      assert Paths.new_integration() =~ "/admin/settings/integrations/new"

      refute Paths.integrations() =~ "/profile/"
      refute Paths.new_integration() =~ "/profile/"

      # `"/admin/settings/integrations"` is a substring of the `/new` path, so
      # the assertions above would all still pass if the two helpers were
      # swapped or one were copy-pasted over the other. Pin them apart.
      refute Paths.integrations() =~ "/new"
      assert Paths.integrations() != Paths.new_integration()
    end

    test "integrations paths carry no /website segment" do
      # Core 2.21.3 renamed `/admin/settings/integrations/website` to
      # `/admin/settings/integrations`. The stale path does not 404: it
      # matches core's `/admin/settings/integrations/:uuid` route with
      # `uuid = "website"`, which raises `Ecto.Query.CastError` and turns into
      # a LiveView reload loop. Core hit this on its own sidebar tab and fixed
      # it in 2.22.2; this module linked to the same stale path. Pin it so the
      # segment cannot come back by copy-paste.
      refute Paths.integrations() =~ "/website"
      refute Paths.new_integration() =~ "/website"
    end

    test "all helpers route through PhoenixKit.Utils.Routes (prefix-aware)" do
      # All helpers go through Routes.path/1 — pin that they don't
      # hardcode the prefix. With no `url_prefix` config, the path is
      # returned as-is; with a prefix it would be prepended.
      for path <- [
            Paths.index(),
            Paths.templates(),
            Paths.documents(),
            Paths.settings(),
            Paths.integrations(),
            Paths.new_integration()
          ] do
        assert String.starts_with?(path, "/")
      end
    end
  end
end
