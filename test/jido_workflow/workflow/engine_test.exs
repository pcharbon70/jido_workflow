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

defmodule JidoWorkflow.Workflow.EngineTestActions.Compensate do
  use Jido.Action,
    name: "engine_compensate",
    schema: []

  @impl true
  def run(%{notify_pid: notify_pid} = params, _context) when is_pid(notify_pid) do
    payload =
      params
      |> Map.delete(:notify_pid)
      |> Map.delete("notify_pid")

    send(notify_pid, {:compensated, payload})
    {:ok, %{"status" => "compensated"}}
  end

  def run(_params, _context) do
    {:ok, %{"status" => "compensated"}}
  end
end

defmodule JidoWorkflow.Workflow.EngineTestActions.Slow do
  use Jido.Action,
    name: "engine_slow",
    schema: []

  @impl true
  def run(_params, _context) do
    Process.sleep(50)
    {:ok, %{"status" => "slow_done"}}
  end
end

defmodule JidoWorkflow.Workflow.EngineTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Compiler
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Definition.Channel, as: DefinitionChannel
  alias JidoWorkflow.Workflow.Definition.Settings
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

  test "execute_compiled/3 only emits workflow completion events when channel policy is workflow_complete" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "parse_file",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
            inputs: %{"file_path" => "`input:file_path`"},
            depends_on: []
          }
        ],
        channel: %DefinitionChannel{
          topic: "workflow:engine_example",
          broadcast_events: ["workflow_complete"]
        }
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               bus: bus,
               backend: :direct
             )

    assert execution.status == :completed

    refute_receive {:signal, %Signal{type: "workflow.run.started"}}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{"status" => "completed"}
                    }}
  end

  test "execute_compiled/3 only emits started events when channel policy is step_started" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "parse_file",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
            inputs: %{"file_path" => "`input:file_path`"},
            depends_on: []
          }
        ],
        channel: %DefinitionChannel{
          topic: "workflow:engine_example",
          broadcast_events: ["step_started"]
        }
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               bus: bus,
               backend: :direct
             )

    assert execution.status == :completed
    assert_receive {:signal, %Signal{type: "workflow.run.started", data: %{"run_id" => run_id}}}

    refute_receive {:signal,
                    %Signal{type: "workflow.run.completed", data: %{"run_id" => ^run_id}}}

    refute_receive {:signal, %Signal{type: "workflow.run.failed", data: %{"run_id" => ^run_id}}}
  end

  test "execute_compiled/3 emits step lifecycle signals with channel source when enabled" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "parse_file",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
            inputs: %{"file_path" => "`input:file_path`"},
            depends_on: []
          }
        ],
        channel: %DefinitionChannel{
          topic: "workflow:engine_example",
          broadcast_events: ["step_started", "step_completed"]
        }
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               bus: bus,
               backend: :direct
             )

    assert execution.status == :completed

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.started",
                      source: "/jido_workflow/workflow/workflow%3Aengine_example",
                      data: %{
                        "run_id" => run_id,
                        "step" => %{"name" => "parse_file", "type" => "action"}
                      }
                    }}

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.step.completed",
                      source: "/jido_workflow/workflow/workflow%3Aengine_example",
                      data: %{
                        "run_id" => ^run_id,
                        "status" => "completed",
                        "step" => %{"name" => "parse_file", "type" => "action"}
                      }
                    }}
  end

  test "execute_compiled/3 suppresses step lifecycle signals when policy excludes them" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.step.*", dispatch: {:pid, target: self()})

    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "parse_file",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.ParseFile",
            inputs: %{"file_path" => "`input:file_path`"},
            depends_on: []
          }
        ],
        channel: %DefinitionChannel{
          topic: "workflow:engine_example",
          broadcast_events: ["workflow_complete"]
        }
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               bus: bus,
               backend: :direct
             )

    assert execution.status == :completed
    refute_receive {:signal, %Signal{type: "workflow.step.started"}}
    refute_receive {:signal, %Signal{type: "workflow.step.completed"}}
    refute_receive {:signal, %Signal{type: "workflow.step.failed"}}
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

  test "execute_compiled/3 runs compensation handlers when on_failure is compensate" do
    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "fail_step",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.Fail",
            inputs: %{},
            depends_on: []
          }
        ],
        settings: %Settings{on_failure: "compensate"},
        error_handling: [
          %{
            "handler" => "compensate:fail_step",
            "action" => "JidoWorkflow.Workflow.EngineTestActions.Compensate",
            "inputs" => %{
              "notify_pid" => "`input:test_pid`",
              "file_path" => "`input:file_path`"
            }
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:return_projection_failed, :no_productions}} =
             Engine.execute_compiled(
               compiled,
               %{"test_pid" => self(), "file_path" => "lib/example.ex"},
               backend: :direct
             )

    assert_receive {:compensated, payload}

    assert (Map.get(payload, :file_path) || Map.get(payload, "file_path")) == "lib/example.ex"
  end

  test "execute_compiled/3 does not run compensation handlers when on_failure is halt" do
    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "fail_step",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.Fail",
            inputs: %{},
            depends_on: []
          }
        ],
        settings: %Settings{on_failure: "halt"},
        error_handling: [
          %{
            "handler" => "compensate:fail_step",
            "action" => "JidoWorkflow.Workflow.EngineTestActions.Compensate",
            "inputs" => %{
              "notify_pid" => "`input:test_pid`"
            }
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:return_projection_failed, :no_productions}} =
             Engine.execute_compiled(compiled, %{"test_pid" => self()}, backend: :direct)

    refute_receive {:compensated, _}
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

  test "execute_compiled/3 suppresses failed signal when channel policy excludes workflow_complete" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "fail_step",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.Fail",
            inputs: %{},
            depends_on: []
          }
        ],
        channel: %DefinitionChannel{
          topic: "workflow:engine_example",
          broadcast_events: ["step_started"]
        }
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:return_projection_failed, :no_productions}} =
             Engine.execute_compiled(compiled, %{}, bus: bus, backend: :direct)

    assert_receive {:signal, %Signal{type: "workflow.run.started", data: %{"run_id" => run_id}}}
    refute_receive {:signal, %Signal{type: "workflow.run.failed", data: %{"run_id" => ^run_id}}}
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

  test "execute_compiled/3 applies compiled settings timeout for strategy backend await" do
    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "slow_step",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.Slow",
            inputs: %{},
            depends_on: []
          }
        ],
        settings: %Settings{timeout_ms: 1}
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:execution_failed, reason}} =
             Engine.execute_compiled(compiled, %{}, backend: :strategy)

    assert match?({:await_completion_failed, {:timeout, _}}, reason)
  end

  test "execute_compiled/3 lets explicit opts override compiled timeout settings" do
    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "slow_step",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.Slow",
            inputs: %{},
            depends_on: []
          }
        ],
        settings: %Settings{timeout_ms: 1}
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{},
               backend: :direct,
               timeout: 1_000
             )

    assert execution.status == :completed
    assert execution.workflow_id == "engine_example"
    assert execution.result["results"]["slow_step"]["status"] == "slow_done"
  end

  defp base_definition(steps, opts \\ []) do
    %Definition{
      name: "engine_example",
      version: "1.0.0",
      description: "engine test",
      enabled: true,
      inputs: [],
      triggers: [],
      settings: Keyword.get(opts, :settings),
      channel: Keyword.get(opts, :channel),
      steps: steps,
      error_handling: Keyword.get(opts, :error_handling, []),
      return: nil
    }
  end

  defp start_test_bus do
    bus = String.to_atom("jido_workflow_engine_test_bus_#{System.unique_integer([:positive])}")
    start_supervised!({Bus, name: bus})
    bus
  end
end
