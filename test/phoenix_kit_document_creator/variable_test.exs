defmodule PhoenixKitDocumentCreator.VariableTest do
  use ExUnit.Case, async: true

  describe "struct shape" do
    test "variable has a config map, defaulting to empty" do
      v = %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: :text}
      assert v.config == %{}
    end

    test "image and image_list are valid types" do
      for t <- [:image, :image_list] do
        assert %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: t}.type == t
      end
    end
  end
end
