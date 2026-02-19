defmodule JidoWorkflow.Workflow.HooksIntegration do
  @moduledoc """
  Integrates workflow lifecycle signals with hook adapters.
  """

  require Logger

  alias Jido.Signal
  alias JidoWorkflow.Workflow.Hooks.NoopAdapter

  @signal_hook_mapping %{
    "workflow.run.started" => :before_workflow,
    "workflow.step.started" => :before_workflow_step,
    "workflow.step.completed" => :after_workflow_step,
    "workflow.step.failed" => :after_workflow_step,
    "workflow.run.completed" => :after_workflow,
    "workflow.run.failed" => :after_workflow,
    "workflow.run.cancelled" => :after_workflow
  }

  @spec supported_signal_types() :: [String.t()]
  def supported_signal_types do
    @signal_hook_mapping
    |> Map.keys()
    |> Enum.sort()
  end

  @spec hook_for_signal(String.t()) :: atom() | nil
  def hook_for_signal(signal_type) when is_binary(signal_type) do
    Map.get(@signal_hook_mapping, signal_type)
  end

  def hook_for_signal(_signal_type), do: nil

  @spec emit_signal_hook(Signal.t(), keyword()) :: :ok
  def emit_signal_hook(%Signal{} = signal, opts \\ []) do
    case hook_for_signal(signal.type) do
      nil ->
        :ok

      hook_name ->
        emit_workflow_hooks(hook_name, hook_payload(signal), opts)
    end
  end

  @spec emit_workflow_hooks(atom(), map(), keyword()) :: :ok
  def emit_workflow_hooks(event_type, payload, opts \\ [])
      when is_atom(event_type) and is_map(payload) do
    invoke_adapter(resolve_adapter(opts), event_type, payload)
  end

  defp hook_payload(%Signal{} = signal) do
    data = stringify_keys(signal.data)

    %{
      "event_type" => signal.type,
      "signal_id" => signal.id,
      "signal_source" => signal.source,
      "workflow_id" => fetch(data, "workflow_id"),
      "run_id" => fetch(data, "run_id"),
      "step" => normalize_step(fetch(data, "step")),
      "status" => fetch(data, "status"),
      "reason" => fetch(data, "reason"),
      "data" => data
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_step(%{} = step) do
    %{
      "name" => fetch(step, "name"),
      "type" => fetch(step, "type")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_step(_step), do: nil

  defp resolve_adapter(opts) do
    case Keyword.get(opts, :adapter, default_adapter()) do
      module when is_atom(module) -> module
      _other -> NoopAdapter
    end
  end

  defp default_adapter do
    Application.get_env(:jido_workflow, :workflow_hook_adapter, NoopAdapter)
  end

  defp invoke_adapter(adapter, hook_name, payload) do
    with {:module, _loaded} <- Code.ensure_loaded(adapter),
         true <- function_exported?(adapter, :run, 2) do
      case adapter.run(hook_name, payload) do
        :ok ->
          :ok

        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.warning("Workflow hook #{hook_name} failed: #{inspect(reason)}")
          :ok

        other ->
          Logger.warning(
            "Workflow hook #{hook_name} returned unexpected value: #{inspect(other)}"
          )

          :ok
      end
    else
      _ ->
        Logger.warning("Workflow hook adapter #{inspect(adapter)} is missing run/2")
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Workflow hook #{hook_name} raised in #{inspect(adapter)}: #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Workflow hook #{hook_name} exited in #{inspect(adapter)}: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, item} ->
      {to_string(key), stringify_keys(item)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        fetch_atom_key(map, key)
    end
  end

  defp fetch(_map, _key), do: nil

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end
end
