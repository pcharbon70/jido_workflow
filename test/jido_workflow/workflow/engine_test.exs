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

defmodule JidoWorkflow.Workflow.EngineTestActions.CaptureBackend do
  use Jido.Action,
    name: "engine_capture_backend",
    schema: [
      workflow: [type: :any, required: true]
    ]

  @impl true
  def run(%{workflow: workflow}, _context) do
    result =
      %{}
      |> maybe_put("backend", fetch(workflow, "backend"))
      |> maybe_put("signal_topic", fetch(workflow, "signal_topic"))
      |> maybe_put("publish_events", fetch(workflow, "publish_events"))

    {:ok, result}
  end

  defp maybe_put(result, _key, nil), do: result
  defp maybe_put(result, key, value), do: Map.put(result, key, value)

  defp fetch(workflow, key) when is_map(workflow) do
    Map.get(workflow, key) ||
      Enum.find_value(workflow, fn
        {map_key, map_value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: map_value

        _other ->
          nil
      end)
  end

  defp fetch(_workflow, _key), do: nil
end

defmodule JidoWorkflow.Workflow.EngineTest do
  use ExUnit.Case, async: false

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Compiler
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Definition.Input, as: DefinitionInput
  alias JidoWorkflow.Workflow.Definition.Settings
  alias JidoWorkflow.Workflow.Definition.Signals, as: DefinitionSignals
  alias JidoWorkflow.Workflow.Definition.Step, as: DefinitionStep
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.RunStore
  alias JidoWorkflow.Workflow.ValidationError

  test "execute_compiled/3 exposes runtime backend in workflow context inputs" do
    definition =
      base_definition([
        %DefinitionStep{
          name: "capture_backend",
          type: "action",
          module: "JidoWorkflow.Workflow.EngineTestActions.CaptureBackend",
          inputs: %{"workflow" => "`input:__workflow`"},
          depends_on: []
        }
      ])

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} = Engine.execute_compiled(compiled, %{}, backend: :direct)
    assert execution.result["results"]["capture_backend"]["backend"] == "direct"
  end

  test "execute_compiled/3 injects signal policy context" do
    definition =
      base_definition(
        [
          %DefinitionStep{
            name: "capture_backend",
            type: "action",
            module: "JidoWorkflow.Workflow.EngineTestActions.CaptureBackend",
            inputs: %{"workflow" => "`input:__workflow`"},
            depends_on: []
          }
        ],
        signals: %DefinitionSignals{
          topic: "workflow:engine_context",
          publish_events: ["step_started", "workflow_complete"]
        }
      )

    assert {:ok, compiled} = Compiler.compile(definition)
    assert {:ok, execution} = Engine.execute_compiled(compiled, %{}, backend: :direct)

    workflow_context = execution.result["results"]["capture_backend"]

    assert workflow_context["backend"] == "direct"
    assert workflow_context["signal_topic"] == "workflow:engine_context"
    assert workflow_context["publish_events"] == ["step_started", "workflow_complete"]
  end

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

  test "execute_compiled/3 invokes runtime-agent callback when using strategy backend" do
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

    callback = fn runtime_agent_pid ->
      send(self(), {:runtime_agent_started, runtime_agent_pid})
    end

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               backend: :strategy,
               await_timeout: 30_000,
               on_runtime_agent_started: callback
             )

    assert execution.status == :completed
    assert_receive {:runtime_agent_started, runtime_agent_pid}
    assert is_pid(runtime_agent_pid)
  end

  test "execute_compiled/3 only emits workflow completion events when publish policy is workflow_complete" do
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
        signals: %DefinitionSignals{
          topic: "workflow:engine_example",
          publish_events: ["workflow_complete"]
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

  test "execute_compiled/3 only emits started events when publish policy is step_started" do
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
        signals: %DefinitionSignals{
          topic: "workflow:engine_example",
          publish_events: ["step_started"]
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

  test "execute_compiled/3 emits step lifecycle signals with signal source when enabled" do
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
        signals: %DefinitionSignals{
          topic: "workflow:engine_example",
          publish_events: ["step_started", "step_completed"]
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
        signals: %DefinitionSignals{
          topic: "workflow:engine_example",
          publish_events: ["workflow_complete"]
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

  test "execute_compiled/3 applies declared input defaults before workflow execution" do
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
        inputs: [
          %DefinitionInput{
            name: "file_path",
            type: "string",
            required: true,
            default: nil,
            description: nil
          },
          %DefinitionInput{
            name: "diff_content",
            type: "string",
            required: false,
            default: "diff unavailable",
            description: nil
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               backend: :direct
             )

    assert execution.status == :completed
    assert execution.result["inputs"]["file_path"] == "lib/example.ex"
    assert execution.result["inputs"]["diff_content"] == "diff unavailable"
  end

  test "execute_compiled/3 rejects missing required workflow inputs before starting workflow" do
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

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
        inputs: [
          %DefinitionInput{
            name: "file_path",
            type: "string",
            required: true,
            default: nil,
            description: nil
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error,
            {:invalid_inputs,
             [%ValidationError{path: ["inputs", "file_path"], code: :required} | _]}} =
             Engine.execute_compiled(compiled, %{}, bus: bus, backend: :direct)

    refute_receive {:signal, %Signal{type: "workflow.run.started"}}

    assert_receive {:signal, %Signal{type: "workflow.run.failed", data: %{"reason" => reason}}}

    assert is_binary(reason)
    assert String.contains?(reason, "invalid_inputs")
  end

  test "execute_compiled/3 rejects workflow input values with invalid declared types" do
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
        inputs: [
          %DefinitionInput{
            name: "retry_count",
            type: "integer",
            required: true,
            default: nil,
            description: nil
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error,
            {:invalid_inputs,
             [%ValidationError{path: ["inputs", "retry_count"], code: :invalid_type} | _]}} =
             Engine.execute_compiled(compiled, %{"retry_count" => "3"}, backend: :direct)
  end

  test "execute_compiled/3 records completed run lifecycle state in run store" do
    run_store = start_test_run_store()

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

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               backend: :direct,
               run_store: run_store
             )

    assert {:ok, run} = RunStore.get(execution.run_id, run_store)
    assert run.status == :completed
    assert run.workflow_id == "engine_example"
    assert run.backend == :direct
    assert run.inputs["file_path"] == "lib/example.ex"
    assert run.result == execution.result
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.finished_at
  end

  test "execute_compiled/3 records failed run state for invalid input contract failures" do
    run_store = start_test_run_store()
    run_id = "run_invalid_inputs"

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
        inputs: [
          %DefinitionInput{
            name: "file_path",
            type: "string",
            required: true,
            default: nil,
            description: nil
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error, {:invalid_inputs, _errors}} =
             Engine.execute_compiled(compiled, %{},
               backend: :direct,
               run_id: run_id,
               run_store: run_store
             )

    assert {:ok, run} = RunStore.get(run_id, run_store)
    assert run.status == :failed
    assert run.workflow_id == "engine_example"
    assert run.backend == :direct
    assert run.inputs == %{}
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.finished_at
    assert match?({:invalid_inputs, [_ | _]}, run.error)
  end

  test "execute_compiled/3 completes when run_store is unavailable during lifecycle recording" do
    run_store = start_test_run_store()
    run_store_pid = Process.whereis(run_store)
    assert is_pid(run_store_pid)
    :ok = GenServer.stop(run_store_pid, :normal)

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

    assert {:ok, execution} =
             Engine.execute_compiled(compiled, %{"file_path" => "lib/example.ex"},
               backend: :direct,
               run_store: run_store
             )

    assert execution.status == :completed
    assert execution.workflow_id == "engine_example"
    assert execution.result["results"]["parse_file"]["ast"] == "ast:lib/example.ex"
  end

  test "execute_compiled/3 returns invalid input errors when run_store is unavailable" do
    run_store = start_test_run_store()
    run_store_pid = Process.whereis(run_store)
    assert is_pid(run_store_pid)
    :ok = GenServer.stop(run_store_pid, :normal)

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
        inputs: [
          %DefinitionInput{
            name: "file_path",
            type: "string",
            required: true,
            default: nil,
            description: nil
          }
        ]
      )

    assert {:ok, compiled} = Compiler.compile(definition)

    assert {:error,
            {:invalid_inputs,
             [%ValidationError{path: ["inputs", "file_path"], code: :required} | _]}} =
             Engine.execute_compiled(compiled, %{},
               backend: :direct,
               run_store: run_store,
               run_id: "run_store_unavailable_invalid_inputs"
             )
  end

  test "get_run/2 and list_runs/1 delegate to configured run store" do
    run_store = start_test_run_store()

    assert :ok =
             RunStore.record_started(
               %{run_id: "run_a", workflow_id: "flow_a", backend: :direct},
               run_store
             )

    assert :ok =
             RunStore.record_failed(
               "run_a",
               :boom,
               %{workflow_id: "flow_a", backend: :direct},
               run_store
             )

    assert :ok =
             RunStore.record_started(
               %{run_id: "run_b", workflow_id: "flow_b", backend: :strategy},
               run_store
             )

    assert {:ok, run} = Engine.get_run("run_a", run_store: run_store)
    assert run.workflow_id == "flow_a"
    assert run.status == :failed

    assert Enum.map(Engine.list_runs(run_store: run_store), & &1.run_id) == ["run_b", "run_a"]

    assert Enum.map(Engine.list_runs(run_store: run_store, workflow_id: "flow_a"), & &1.run_id) ==
             [
               "run_a"
             ]
  end

  test "pause/2, resume/2 and cancel/2 apply run control transitions in run store" do
    run_store = start_test_run_store()
    bus = start_test_bus()

    assert {:ok, _sub_id} =
             Bus.subscribe(bus, "workflow.run.*", dispatch: {:pid, target: self()})

    assert :ok =
             RunStore.record_started(
               %{run_id: "run_ctrl", workflow_id: "flow", backend: :direct},
               run_store
             )

    assert :ok = Engine.pause("run_ctrl", run_store: run_store, bus: bus)
    assert {:ok, paused} = RunStore.get("run_ctrl", run_store)
    assert paused.status == :paused

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.paused",
                      data: %{"run_id" => "run_ctrl", "status" => "paused"}
                    }}

    assert :ok = Engine.resume("run_ctrl", run_store: run_store, bus: bus)
    assert {:ok, resumed} = RunStore.get("run_ctrl", run_store)
    assert resumed.status == :running

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.resumed",
                      data: %{"run_id" => "run_ctrl", "status" => "running"}
                    }}

    assert :ok = Engine.cancel("run_ctrl", run_store: run_store, bus: bus)
    assert {:ok, cancelled} = RunStore.get("run_ctrl", run_store)
    assert cancelled.status == :cancelled
    assert cancelled.error == :cancelled

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.cancelled",
                      data: %{"run_id" => "run_ctrl", "status" => "cancelled"}
                    }}
  end

  test "pause/2, resume/2 and cancel/2 return transition errors for invalid state changes" do
    run_store = start_test_run_store()

    assert :ok =
             RunStore.record_completed(
               "run_done",
               %{ok: true},
               %{workflow_id: "flow", backend: :direct},
               run_store
             )

    assert {:error, {:invalid_transition, %{from: :completed, to: :paused}}} =
             Engine.pause("run_done", run_store: run_store)

    assert {:error, {:invalid_transition, %{from: :completed, to: :running}}} =
             Engine.resume("run_done", run_store: run_store)

    assert {:error, {:invalid_transition, %{from: :completed, to: :cancelled}}} =
             Engine.cancel("run_done", run_store: run_store)

    assert {:error, :not_found} = Engine.pause("missing", run_store: run_store)
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

  test "execute_compiled/3 suppresses failed signal when publish policy excludes workflow_complete" do
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
        signals: %DefinitionSignals{
          topic: "workflow:engine_example",
          publish_events: ["step_started"]
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
      inputs: Keyword.get(opts, :inputs, []),
      triggers: [],
      settings: Keyword.get(opts, :settings),
      signals: Keyword.get(opts, :signals),
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

  defp start_test_run_store do
    name = String.to_atom("jido_workflow_run_store_test_#{System.unique_integer([:positive])}")
    start_supervised!({RunStore, name: name})
    name
  end
end
