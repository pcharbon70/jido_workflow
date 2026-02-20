defmodule JidoWorkflow.Workflow.Broadcaster do
  @moduledoc """
  Emits workflow lifecycle events as Jido signals.
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

  @spec broadcast_workflow_paused(String.t(), String.t(), map(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_workflow_paused(workflow_id, run_id, metadata \\ %{}, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "status" => "paused",
      "metadata" => metadata,
      "paused_at" => timestamp()
    }

    publish("workflow.run.paused", payload, opts)
  end

  @spec broadcast_workflow_resumed(String.t(), String.t(), map(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_workflow_resumed(workflow_id, run_id, metadata \\ %{}, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "status" => "running",
      "metadata" => metadata,
      "resumed_at" => timestamp()
    }

    publish("workflow.run.resumed", payload, opts)
  end

  @spec broadcast_workflow_cancelled(String.t(), String.t(), term(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_workflow_cancelled(workflow_id, run_id, reason, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "status" => "cancelled",
      "reason" => format_reason(reason),
      "cancelled_at" => timestamp()
    }

    publish("workflow.run.cancelled", payload, opts)
  end

  @spec broadcast_step_started(String.t(), String.t(), map(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_step_started(workflow_id, run_id, step, opts \\ []) when is_map(step) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "step" => normalize_step(step),
      "started_at" => timestamp()
    }

    publish("workflow.step.started", payload, opts)
  end

  @spec broadcast_step_completed(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_step_completed(workflow_id, run_id, step, result, opts \\ []) when is_map(step) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "step" => normalize_step(step),
      "status" => "completed",
      "result" => result,
      "completed_at" => timestamp()
    }

    publish("workflow.step.completed", payload, opts)
  end

  @spec broadcast_step_failed(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_step_failed(workflow_id, run_id, step, reason, opts \\ []) when is_map(step) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "step" => normalize_step(step),
      "status" => "failed",
      "reason" => format_reason(reason),
      "failed_at" => timestamp()
    }

    publish("workflow.step.failed", payload, opts)
  end

  @spec broadcast_agent_state(String.t(), String.t(), String.t() | atom(), term(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def broadcast_agent_state(workflow_id, run_id, agent_name, state, opts \\ []) do
    payload = %{
      "workflow_id" => workflow_id,
      "run_id" => run_id,
      "agent" => to_string(agent_name),
      "state" => normalize_agent_state(state),
      "timestamp" => timestamp()
    }

    publish("workflow.agent.state", payload, opts)
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

  defp normalize_step(step) do
    %{
      "name" => fetch_step_value(step, "name"),
      "type" => fetch_step_value(step, "type")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fetch_step_value(step, key) do
    Map.get(step, key) ||
      fetch_step_atom_value(step, key) ||
      Enum.find_value(step, fn
        {map_key, map_value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: map_value

        _other ->
          nil
      end)
  end

  defp fetch_step_atom_value(step, "name"), do: Map.get(step, :name)
  defp fetch_step_atom_value(step, "type"), do: Map.get(step, :type)
  defp fetch_step_atom_value(_step, _key), do: nil

  defp normalize_agent_state(state) when is_map(state), do: stringify_keys(state)
  defp normalize_agent_state(state) when is_atom(state), do: Atom.to_string(state)
  defp normalize_agent_state(state), do: state

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, item} ->
      {to_string(key), stringify_keys(item)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
