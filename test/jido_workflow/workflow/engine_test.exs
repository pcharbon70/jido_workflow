defmodule JidoWorkflow.Workflow.EngineTestActions.ParseFile do
  use Jido.Action,
    name: "engine_parse_file",
    schema: [
      file_path: [type: :string, required: true]
    ]

  @impl true
  def run(%{file_path: file_path}, _context) do
    {:ok, %{"ast" => "ast:#{file_path}"}}
  end
end

defmodule JidoWorkflow.Workflow.EngineTestActions.BuildSummary do
  use Jido.Action,
    name: "engine_build_summary",
    schema: [
      ast: [type: :string, required: true]
    ]

  @impl true
  def run(%{ast: ast}, _context) do
    {:ok, %{"summary" => "summary:#{ast}"}}
  end
end

defmodule JidoWorkflow.Workflow.EngineTestActions.Fail do
  use Jido.Action,
    name: "engine_fail",
    schema: []

  @impl true
  def run(_params, _context) do
    {:error, :boom}
  end
end

defmodule JidoWorkflow.Workflow.EngineTest do
  use ExUnit.Case, async: true

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Compiler
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Definition.Step, as: DefinitionStep
  alias JidoWorkflow.Workflow.Engine

  test "execute_compiled/3 executes workflow and projects configured return value (direct backend)" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition([
        %DefinitionStep{
          name: "parse_file",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
          inputs: %{"file_path" => "`input:file_path`"},
          depends_on: []
        },
        %DefinitionStep{
          name: "build_summary",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.BuildSummary",
          inputs: %{"ast" => "`result:parse_file.ast`"},
          depends_on: ["parse_file"]
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    compiled =
      Map.put(compiled, :return, %{
        value: "build_summary",
        transform: "fn result -> Map.get(result, \"summary\") end"
      })

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               bus: bus,
               backend: :direct
             )

    assert execution.status == :completed
    assert execution.workflow_id == "engine_example"
    assert execution.result == "summary:ast:lib/example.ex"

    assert_receive {:signal, %Signal{type: "workflow.run.started", data: %{"run_id" => run_id}}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{"run_id" => ^run_id, "status" => "completed"}
                    }}
  end

  test "execute_compiled/3 executes workflow and projects configured return value (strategy backend)" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition([
        %DefinitionStep{
          name: "parse_file",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
          inputs: %{"file_path" => "`input:file_path`"},
          depends_on: []
        },
        %DefinitionStep{
          name: "build_summary",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.BuildSummary",
          inputs: %{"ast" => "`result:parse_file.ast`"},
          depends_on: ["parse_file"]
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    compiled =
      Map.put(compiled, :return, %{
        value: "build_summary",
        transform: "fn result -> Map.get(result, \"summary\") end"
      })

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               bus: bus,
               backend: :strategy,
               await_timeout: 30_000
             )

    assert execution.status == :completed
    assert execution.workflow_id == "engine_example"
    assert execution.result == "summary:ast:lib/example.ex"

    assert_receive {:signal, %Signal{type: "workflow.run.started", data: %{"run_id" => run_id}}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{"run_id" => ^run_id, "status" => "completed"}
                    }}
  end

  test "execute_compiled/3 broadcasts failed signal when execution fails (direct backend)" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition([
        %DefinitionStep{
          name: "fail_step",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.Fail",
          inputs: %{},
          depends_on: []
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:return_projection_failed, :no_productions}} =
             Engine.execute_compiled(compiled, %{}, bus: bus, backend: :direct)

    assert_receive {:signal, %Signal{type: "workflow.run.started", data: %{"run_id" => run_id}}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.failed",
                      data: %{"run_id" => ^run_id, "status" => "failed"}
                    }}
  end

  test "execute_compiled/3 broadcasts failed signal when execution fails (strategy backend)" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition([
        %DefinitionStep{
          name: "fail_step",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.Fail",
          inputs: %{},
          depends_on: []
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:execution_failed, reason}} =
             Engine.execute_compiled(compiled, %{},
               bus: bus,
               backend: :strategy,
               await_timeout: 30_000
             )

    assert match?({:runic_failed, _}, reason) or
             match?({:await_completion_failed, {:timeout, _}}, reason)

    assert_receive {:signal, %Signal{type: "workflow.run.started", data: %{"run_id" => run_id}}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.failed",
                      data: %{"run_id" => ^run_id, "status" => "failed"}
                    }}
  end

  test "execute_compiled/3 returns invalid backend error for unsupported backend option" do
    definition =
      base_definition([
        %DefinitionStep{
          name: "parse_file",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
          inputs: %{"file_path" => "`input:file_path`"},
          depends_on: []
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:invalid_backend, :unknown}} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               backend: :unknown
             )
  end

  defp base_definition(steps) do
    %Definition{
      name: "engine_example",
      version: "1.0.0",
      description: "engine test",
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

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_engine_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
