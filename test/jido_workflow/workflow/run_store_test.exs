defmodule JidoWorkflow.Workflow.RunStoreTest do
  use ExUnit.Case, async: true

  alias JidoWorkflow.Workflow.RunStore

  setup do
    name = String.to_atom("workflow_run_store_#{System.unique_integer([:positive])}")
    pid = start_supervised!({RunStore, name: name, max_runs: 3})
    {:ok, run_store: name, run_store_pid: pid}
  end

  test "records started and completed run state", %{run_store: run_store} do
    assert :ok =
             RunStore.record_started(
               %{
                 run_id: "run_1",
                 workflow_id: "example",
                 backend: :direct,
                 inputs: %{"file_path" => "lib/example.ex"}
               },
               run_store
             )

    assert :ok = RunStore.record_completed("run_1", %{ok: true}, %{}, run_store)

    assert {:ok, run} = RunStore.get("run_1", run_store)
    assert run.status == :completed
    assert run.workflow_id == "example"
    assert run.backend == :direct
    assert run.inputs["file_path"] == "lib/example.ex"
    assert run.result == %{ok: true}
    assert run.error == nil
    assert %DateTime{} = run.started_at
    assert %DateTime{} = run.finished_at
  end

  test "records failed run state without prior start event", %{run_store: run_store} do
    assert :ok =
             RunStore.record_failed(
               "run_2",
               {:invalid_inputs, :missing_required},
               %{workflow_id: "example", backend: :strategy},
               run_store
             )

    assert {:ok, run} = RunStore.get("run_2", run_store)
    assert run.status == :failed
    assert run.workflow_id == "example"
    assert run.backend == :strategy
    assert run.result == nil
    assert run.error == {:invalid_inputs, :missing_required}
  end

  test "lists runs newest-first and respects filters and limits", %{run_store: run_store} do
    assert :ok = RunStore.record_started(%{run_id: "run_a", workflow_id: "flow_a"}, run_store)
    assert :ok = RunStore.record_completed("run_a", :ok, %{}, run_store)
    assert :ok = RunStore.record_started(%{run_id: "run_b", workflow_id: "flow_b"}, run_store)
    assert :ok = RunStore.record_failed("run_b", :boom, %{}, run_store)
    assert :ok = RunStore.record_started(%{run_id: "run_c", workflow_id: "flow_a"}, run_store)

    assert Enum.map(RunStore.list(run_store), & &1.run_id) == ["run_c", "run_b", "run_a"]

    assert Enum.map(RunStore.list(run_store, workflow_id: "flow_a"), & &1.run_id) == [
             "run_c",
             "run_a"
           ]

    assert Enum.map(RunStore.list(run_store, status: :failed), & &1.run_id) == ["run_b"]
    assert Enum.map(RunStore.list(run_store, limit: 2), & &1.run_id) == ["run_c", "run_b"]
  end

  test "prunes oldest runs when max_runs limit is exceeded", %{run_store: run_store} do
    assert :ok = RunStore.record_started(%{run_id: "run_1", workflow_id: "flow"}, run_store)
    assert :ok = RunStore.record_started(%{run_id: "run_2", workflow_id: "flow"}, run_store)
    assert :ok = RunStore.record_started(%{run_id: "run_3", workflow_id: "flow"}, run_store)
    assert :ok = RunStore.record_started(%{run_id: "run_4", workflow_id: "flow"}, run_store)

    assert Enum.map(RunStore.list(run_store), & &1.run_id) == ["run_4", "run_3", "run_2"]
    assert {:error, :not_found} = RunStore.get("run_1", run_store)
  end
end
