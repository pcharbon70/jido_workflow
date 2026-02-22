defmodule Jido.Code.Workflow.LoaderTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.Definition
  alias Jido.Code.Workflow.Loader

  @fixture Path.expand("../../../support/fixtures/workflows/code_review_pipeline.md", __DIR__)

  test "load_file/1 parses and validates into a typed definition" do
    assert {:ok, %Definition{} = definition} = Loader.load_file(@fixture)

    assert definition.name == "code_review_pipeline"
    assert definition.version == "1.0.0"
    assert length(definition.steps) == 3
    assert definition.return.value == "ai_code_review"
  end
end
