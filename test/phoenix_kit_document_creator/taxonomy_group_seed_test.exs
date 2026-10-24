defmodule PhoenixKitDocumentCreator.TaxonomyGroupSeedTest do
  @moduledoc """
  Covers the code seed for the canonical group order (part А):
  `Taxonomy.ensure_default_group_order/2`.
  """
  use PhoenixKitDocumentCreator.DataCase, async: true

  alias PhoenixKitDocumentCreator.Taxonomy

  @canonical ~w(
    Hinnapakkumine Eeltellimus Moodistamine Tellimus Leping
    Joonised Vastuvõtuakt Garantii Hooldusjuhend
  )

  test "default_group_order/0 lists the 9 canonical groups in order" do
    assert Taxonomy.default_group_order() == @canonical
  end

  test "creates all 9 groups under a category in canonical order" do
    {:ok, cat} = Taxonomy.create_category(%{name: "Klient document"})

    assert :ok = Taxonomy.ensure_default_group_order(cat.uuid)

    names = cat.uuid |> Taxonomy.list_types_for_category() |> Enum.map(& &1.name)
    assert names == @canonical
  end

  test "repositions a pre-existing group instead of duplicating it, and is idempotent" do
    {:ok, cat} = Taxonomy.create_category(%{name: "Tootmine"})
    # "Tellimus" exists first, out of canonical order (it should end at index 3).
    {:ok, _} = Taxonomy.create_type(%{name: "Tellimus", category_uuid: cat.uuid})

    assert :ok = Taxonomy.ensure_default_group_order(cat.uuid)
    # Running twice must not create duplicates or reorder.
    assert :ok = Taxonomy.ensure_default_group_order(cat.uuid)

    types = Taxonomy.list_types_for_category(cat.uuid)
    names = Enum.map(types, & &1.name)

    assert names == @canonical
    assert Enum.count(names, &(&1 == "Tellimus")) == 1
    # Positions are 0..8 in canonical order.
    assert Enum.map(types, & &1.position) == Enum.to_list(0..8)
  end
end
