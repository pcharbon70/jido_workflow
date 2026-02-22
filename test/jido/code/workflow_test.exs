defmodule Jido.Code.WorkflowTest do
  use ExUnit.Case
  alias Jido.Code.Workflow

  doctest Jido.Code.Workflow

  test "greets the world" do
    assert Workflow.hello() == :world
  end
end
