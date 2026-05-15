defmodule PhoenixKitDocumentCreator.Schemas.CategoryTest do
  use ExUnit.Case, async: true

  alias PhoenixKitDocumentCreator.Schemas.Category

  test "valid changeset with name" do
    cs = Category.changeset(%Category{}, %{name: "Financial"})
    assert cs.valid?
  end

  test "name is required" do
    cs = Category.changeset(%Category{}, %{})
    refute cs.valid?
    assert %{name: _} = errors_on(cs)
  end

  test "status must be active or deleted" do
    cs = Category.changeset(%Category{}, %{name: "X", status: "bogus"})
    refute cs.valid?
  end

  defp errors_on(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
  end
end
