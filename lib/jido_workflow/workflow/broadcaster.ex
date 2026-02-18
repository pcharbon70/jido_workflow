defmodule JidoWorkflow.Workflow.Broadcaster do
  @moduledoc """
  Emits workflow lifecycle events as Jido signals.

  This replaces Phoenix channel broadcasting with signal-native pub/sub.
  """

  alias Jido.Signal
  alias Jido.Signal.Bus

  @default_source "/jido_workflow/workflow"

  @spec default_bus() :: atom()
  def default_bus do
    Application.get_env(:jido_workflow, :signal_bus, :jido_workflow_bus)
  end

  @spec broadcast_workflow_started(String.t(), String.t(), map(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_workflow_started(workflow_id, run_id, metadata \\ %{}, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "metadata" => metadata,
      "started_at" => timestamp()
    }

    publish("workflow.run.started", payload, opts)
  end

  @spec broadcast_workflow_completed(String.t(), String.t(), term(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_workflow_completed(workflow_id, run_id, result, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "status" => "completed",
      "result" => result,
      "completed_at" => timestamp()
    }

    publish("workflow.run.completed", payload, opts)
  end

  @spec broadcast_workflow_failed(String.t(), String.t(), term(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_workflow_failed(workflow_id, run_id, reason, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "status" => "failed",
      "reason" => format_reason(reason),
      "failed_at" => timestamp()
    }

    publish("workflow.run.failed", payload, opts)
  end

  defp publish(type, payload, opts) do
    bus = Keyword.get(opts, :bus, default_bus())
    source = Keyword.get(opts, :source, @default_source)

    signal = Signal.new!(type, payload, source: source)
    Bus.publish(bus, [signal])
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_map(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
