defmodule PhoenixKitDocumentCreator.VariableTest do
  use ExUnit.Case, async: true

  describe "struct shape" do
    test "variable has a config map, defaulting to empty" do
      v = %PhoenixKitDocumentCreator.Variable{name: "x", label: "X", type: :text}
      assert v.config == %{}
    end
  end
end
