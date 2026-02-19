defmodule JidoWorkflow.Workflow.CompilerTest do
  use ExUnit.Case, async: true

  alias Jido.Runic.ActionNode
  alias JidoWorkflow.Workflow.Actions.ExecuteAgentStep
  alias JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStep
  alias JidoWorkflow.Workflow.Compiler
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Definition.Step, as: DefinitionStep
  alias JidoWorkflow.Workflow.Loader
  alias Runic.Workflow

  @fixture "/Users/Pascal/code/jido/jido_workflow/test/support/fixtures/workflows/code_review_pipeline.md"

  test "compile/1 builds a Runic workflow bundle from a validated definition" do
    assert {:ok, definition} = Loader.load_file(@fixture)
    assert {:ok, compiled} = Compiler.compile(definition)

    assert %Workflow{} = compiled.workflow
    assert compiled.return.value == "ai_code_review"
    assert compiled.metadata.name == "code_review_pipeline"
    assert compiled.settings.max_concurrency == 4
    assert compiled.settings.timeout_ms == 300_000
    assert compiled.settings.on_failure == "compensate"
    assert compiled.settings.retry_policy.max_retries == 3

    assert %ActionNode{name: "parse_file"} =
             Workflow.get_component(compiled.workflow, "parse_file")

    assert %ActionNode{
             name: "ai_code_review",
             action_mod: ExecuteAgentStep,
             params: %{step: %{agent: "code_reviewer"}}
           } =
             Workflow.get_component(compiled.workflow, "ai_code_review")

    assert %ActionNode{
             name: "apply_fixes",
             action_mod: ExecuteSubWorkflowStep,
             params: %{step: %{workflow: "auto_fix_pipeline"}}
           } =
             Workflow.get_component(compiled.workflow, "apply_fixes")

    assert Map.has_key?(compiled.workflow.components, "parse_file")
    assert Map.has_key?(compiled.workflow.components, "ai_code_review")
    assert Map.has_key?(compiled.workflow.components, "apply_fixes")
  end

  test "compile/1 returns missing dependency errors" do
    definition = base_definition([step("analyze", depends_on: ["missing_step"])])

    assert {:error, errors} = Compiler.compile(definition)

    assert Enum.any?(errors, fn error ->
             error.path == ["steps", "0", "depends_on"] and error.code == :missing_dependency
           end)
  end

  test "compile/1 returns duplicate step name errors" do
    definition =
      base_definition([
        step("duplicate"),
        step("duplicate")
      ])

    assert {:error, errors} = Compiler.compile(definition)

    assert Enum.any?(errors, fn error ->
             error.path == ["steps", "0", "name"] and error.code == :duplicate
           end)
  end

  test "compile/1 detects dependency cycles" do
    definition =
      base_definition([
        step("a", depends_on: ["b"]),
        step("b", depends_on: ["a"])
      ])

    assert {:error, errors} = Compiler.compile(definition)
    assert Enum.any?(errors, &(&1.code == :dependency_cycle))
  end

  defp base_definition(steps) do
    %Definition{
      name: "example_workflow",
      version: "1.0.0",
      description: "example",
      enabled: true,
      inputs: [],
      triggers: [],
      settings: nil,
      channel: nil,
      steps: steps,
      error_handling: [],
      return: nil
    }
  end

  defp step(name, opts \\ []) do
    %DefinitionStep{
      name: name,
      type: Keyword.get(opts, :type, "agent"),
      module: Keyword.get(opts, :module),
      agent: Keyword.get(opts, :agent, "code_reviewer"),
      workflow: Keyword.get(opts, :workflow),
      inputs: Keyword.get(opts, :inputs),
      outputs: Keyword.get(opts, :outputs),
      depends_on: Keyword.get(opts, :depends_on, []),
      async: Keyword.get(opts, :async),
      optional: Keyword.get(opts, :optional),
      mode: Keyword.get(opts, :mode),
      timeout_ms: Keyword.get(opts, :timeout_ms),
      max_retries: Keyword.get(opts, :max_retries),
      pre_actions: Keyword.get(opts, :pre_actions),
      post_actions: Keyword.get(opts, :post_actions),
      condition: Keyword.get(opts, :condition),
      parallel: Keyword.get(opts, :parallel)
    }
  end
end
