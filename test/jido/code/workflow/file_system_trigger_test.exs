defmodule Jido.Code.Workflow.FileSystemTriggerTestActions.CapturePath do
  use Jido.Action,
    name: "file_system_capture_path",
    schema: [
      file_path: [type: :string, required: true]
    ]

  @impl true
  def run(%{file_path: file_path}, _context) do
    {:ok, %{"file_path" => file_path}}
  end
end

defmodule Jido.Code.Workflow.FileSystemTriggerTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Code.Workflow.TriggerSupervisor
  alias Jido.Signal
  alias Jido.Signal.Bus

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "jido_workflow_file_system_trigger_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    watch_dir = Path.join(tmp, "watched")
    File.mkdir_p!(watch_dir)

    bus = unique_name("file_system_trigger_bus")
    start_supervised!({Bus, name: bus})

    workflow_registry = unique_name("file_system_trigger_registry")

    {:ok, workflow_registry_pid} =
      start_supervised({WorkflowRegistry, workflow_dir: tmp, name: workflow_registry})

    process_registry = unique_name("file_system_trigger_process_registry")
    start_supervised!({Registry, keys: :unique, name: process_registry})

    trigger_supervisor = unique_name("file_system_trigger_supervisor")
    start_supervised!({TriggerSupervisor, name: trigger_supervisor})

    write_workflow(tmp, "file_system_flow")
    assert {:ok, %{total: 1}} = WorkflowRegistry.refresh(workflow_registry_pid)

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok,
     tmp_dir: tmp,
     watch_dir: watch_dir,
     bus: bus,
     workflow_registry: workflow_registry_pid,
     process_registry: process_registry,
     trigger_supervisor: trigger_supervisor}
  end

  test "executes workflow on matching file events", context do
    trigger_pid = start_file_system_trigger(context)

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.completed",
               dispatch: {:pid, target: self()}
             )

    changed_path = Path.join(context.watch_dir, "demo.txt")
    send(trigger_pid, {:file_event, self(), {changed_path, [:modified]}})

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "file_system_flow",
                        "result" => %{"file_path" => ^changed_path}
                      }
                    }},
                   5_000
  end

  test "debounces repeated events and ignores unmatched paths", context do
    trigger_pid = start_file_system_trigger(context)

    assert {:ok, _sub_id} =
             Bus.subscribe(context.bus, "workflow.run.completed",
               dispatch: {:pid, target: self()}
             )

    unmatched_path = Path.join(context.tmp_dir, "outside.txt")
    send(trigger_pid, {:file_event, self(), {unmatched_path, [:modified]}})

    matched_path = Path.join(context.watch_dir, "debounced.txt")
    send(trigger_pid, {:file_event, self(), {matched_path, [:created]}})
    send(trigger_pid, {:file_event, self(), {matched_path, [:modified]}})

    assert_receive {:signal,
                    %Signal{
                      type: "workflow.run.completed",
                      data: %{
                        "workflow_id" => "file_system_flow",
                        "result" => %{"file_path" => ^matched_path}
                      }
                    }},
                   5_000

    refute_receive {:signal, %Signal{type: "workflow.run.completed"}}, 250
  end

  defp start_file_system_trigger(context) do
    trigger_id = "file_system_flow:file_system:0"

    assert {:ok, pid} =
             TriggerSupervisor.start_trigger(
               %{
                 id: trigger_id,
                 workflow_id: "file_system_flow",
                 type: "file_system",
                 patterns: ["watched/**/*.txt"],
                 events: ["created", "modified"],
                 debounce_ms: 40,
                 root_dir: context.tmp_dir,
                 workflow_registry: context.workflow_registry,
                 bus: context.bus
               },
               supervisor: context.trigger_supervisor,
               process_registry: context.process_registry
             )

    pid
  end

  defp write_workflow(dir, name) do
    path = Path.join(dir, "#{name}.md")

    markdown = """
    ---
    name: #{name}
    version: "1.0.0"
    enabled: true
    ---

    # #{name}

    ## Steps

    ### capture_path
    - **type**: action
    - **module**: Jido.Code.Workflow.FileSystemTriggerTestActions.CapturePath
    - **inputs**:
      - file_path: `input:file_path`

    ## Return
    - **value**: capture_path
    """

    File.write!(path, markdown)
    path
  end

  defp unique_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
