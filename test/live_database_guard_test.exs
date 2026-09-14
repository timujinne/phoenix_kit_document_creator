defmodule PhoenixKitDocumentCreator.Test.LiveDatabaseGuardTest do
  @moduledoc """
  Pure unit coverage for `check!/1`'s own decision — separate from
  `PhoenixKitDocumentCreator.LiveDatabaseGuardWiringTest`, which proves the
  module is actually reachable from `test_helper.exs`'s real boot sequence,
  not just that its logic is correct in isolation.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Test.LiveDatabaseGuard

  describe "check!/1" do
    test "raises for development and production database names" do
      for db <- ~w(phoenix_kit_dev phoenixkit_hello_world_dev my_app_prod) do
        assert_raise LiveDatabaseGuard.LiveDatabaseError, ~r/#{db}/, fn ->
          LiveDatabaseGuard.check!(db)
        end
      end
    end

    test "the raised message says WHY, not just which database" do
      assert_raise LiveDatabaseGuard.LiveDatabaseError,
                   ~r/PGDATABASE is honored by config\/test.exs/,
                   fn -> LiveDatabaseGuard.check!("phoenix_kit_dev") end
    end

    test "passes an isolated test database name straight through" do
      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_document_creator_test")
      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_document_creator_test1")
    end

    test "passes a pre-provisioned database that does not follow the test naming" do
      # CI service containers commonly hand out `postgres`; requiring `test`
      # in the name would refuse the exact setup PGDATABASE support exists for.
      assert :ok = LiveDatabaseGuard.check!("postgres")
    end

    test "only the suffix counts, not a _dev or _prod appearing mid-name" do
      # A scratch copy named after the database it was cloned from is not the
      # live database itself.
      assert :ok = LiveDatabaseGuard.check!("not_phoenix_kit_dev_but_looks_like_it")
      assert :ok = LiveDatabaseGuard.check!("phoenix_kit_dev_backup")
      assert :ok = LiveDatabaseGuard.check!("my_app_prod_snapshot")
    end

    test "an empty name is never mistaken for a live database" do
      assert :ok = LiveDatabaseGuard.check!("")
    end
  end
end
