defmodule JidoWorkflowTest do
  use ExUnit.Case
  doctest JidoWorkflow

  test "greets the world" do
    assert JidoWorkflow.hello() == :world
  end
end
