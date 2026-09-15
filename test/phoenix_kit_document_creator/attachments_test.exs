defmodule PhoenixKitDocumentCreator.AttachmentsTest do
  # Mutates global application env, which async modules would race on.
  use ExUnit.Case, async: false

  alias PhoenixKitDocumentCreator.Attachments

  defmodule Hook do
    def parent_for(:document_image, actor_uuid, %{template_file_id: template_file_id}) do
      send(self(), {:hook_called, actor_uuid, template_file_id})
      {:ok, "folder-uuid-1234"}
    end
  end

  defmodule TwoArgHook do
    def parent_for(:document_image, actor_uuid) do
      send(self(), {:two_arg_hook_called, actor_uuid})
      {:ok, "folder-uuid-two-arg"}
    end
  end

  defmodule RaisingHook do
    def parent_for(:document_image, _actor_uuid, _subject) do
      raise "boom"
    end
  end

  defmodule ExitingHook do
    def parent_for(:document_image, _actor_uuid, _subject), do: exit(:timeout)
  end

  defmodule ThrowingHook do
    def parent_for(:document_image, _actor_uuid, _subject), do: throw(:nope)
  end

  defmodule NilHook do
    def parent_for(:document_image, _actor_uuid, _subject), do: nil
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_document_creator, :attachments_parent_folder)
    end)
  end

  test "returns nil when no hook is configured" do
    assert Attachments.scope_folder("tpl-1", "actor-1") == nil
  end

  test "calls the configured 3-arg hook with :document_image, actor_uuid and template_file_id" do
    Application.put_env(
      :phoenix_kit_document_creator,
      :attachments_parent_folder,
      {Hook, :parent_for}
    )

    assert Attachments.scope_folder("tpl-1", "actor-1") == "folder-uuid-1234"
    assert_received {:hook_called, "actor-1", "tpl-1"}
  end

  test "falls back to a 2-arg hook when the 3-arg clause is not exported" do
    Application.put_env(
      :phoenix_kit_document_creator,
      :attachments_parent_folder,
      {TwoArgHook, :parent_for}
    )

    assert Attachments.scope_folder("tpl-1", "actor-1") == "folder-uuid-two-arg"
    assert_received {:two_arg_hook_called, "actor-1"}
  end

  test "returns nil when the hook itself returns nil" do
    Application.put_env(
      :phoenix_kit_document_creator,
      :attachments_parent_folder,
      {NilHook, :parent_for}
    )

    assert Attachments.scope_folder("tpl-1", "actor-1") == nil
  end

  test "returns nil (and does not crash) when the hook raises" do
    Application.put_env(
      :phoenix_kit_document_creator,
      :attachments_parent_folder,
      {RaisingHook, :parent_for}
    )

    assert Attachments.scope_folder("tpl-1", "actor-1") == nil
  end

  test "returns nil (and does not crash) when the hook exits or throws" do
    for hook <- [ExitingHook, ThrowingHook] do
      Application.put_env(
        :phoenix_kit_document_creator,
        :attachments_parent_folder,
        {hook, :parent_for}
      )

      assert Attachments.scope_folder("tpl-1", "actor-1") == nil
    end
  end
end
