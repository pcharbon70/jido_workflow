defmodule Jido.Code.Workflow.Triggers.Signal do
  @moduledoc """
  Signal-bus trigger that starts workflow runs when matching signals are received.
  """

  use GenServer

  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Code.Workflow.Engine
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry
  alias Jido.Signal
  alias Jido.Signal.Bus

  @default_process_registry Jido.Code.Workflow.TriggerProcessRegistry

  @type state :: %{
          id: String.t(),
          workflow_id: String.t(),
          bus: atom(),
          patterns: [String.t()],
          subscription_ids: [String.t()],
          workflow_registry: GenServer.server(),
          backend: Engine.backend() | nil
        }

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) when is_map(config) do
    process_registry = fetch(config, "process_registry") || default_process_registry()
    id = fetch(config, "id")

    GenServer.start_link(__MODULE__, config, name: via_tuple(id, process_registry))
  end

  @impl true
  def init(config) do
    id = fetch(config, "id")
    workflow_id = fetch(config, "workflow_id")
    patterns = normalize_patterns(fetch(config, "patterns"))
    bus = fetch(config, "bus") || Broadcaster.default_bus()

    workflow_registry =
      fetch(config, "workflow_registry") || fetch(config, "registry") || WorkflowRegistry

    backend = normalize_backend(fetch(config, "backend"))

    with :ok <- require_binary(id, :id),
         :ok <- require_binary(workflow_id, :workflow_id),
         :ok <- require_patterns(patterns),
         {:ok, subscription_ids} <- subscribe_patterns(bus, patterns) do
      {:ok,
       %{
         id: id,
         workflow_id: workflow_id,
         bus: bus,
         patterns: patterns,
         subscription_ids: subscription_ids,
         workflow_registry: workflow_registry,
         backend: backend
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    payload = signal_payload(signal, state.id)
    _ = execute_workflow(state, payload)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.subscription_ids, fn subscription_id ->
      _ = Bus.unsubscribe(state.bus, subscription_id)
    end)

    :ok
  end

  defp execute_workflow(state, payload) do
    opts =
      [registry: state.workflow_registry, bus: state.bus]
      |> maybe_put_backend(state.backend)

    Engine.execute(state.workflow_id, payload, opts)
  end

  defp maybe_put_backend(opts, nil), do: opts
  defp maybe_put_backend(opts, backend), do: Keyword.put(opts, :backend, backend)

  defp signal_payload(signal, trigger_id) do
    data =
      case signal.data do
        map when is_map(map) -> stringify_keys(map)
        other -> %{"signal_data" => other}
      end

    data
    |> Map.put("trigger_type", "signal")
    |> Map.put("trigger_id", trigger_id)
    |> Map.put("triggered_at", timestamp())
    |> Map.put("signal_type", signal.type)
    |> Map.put("signal_source", signal.source)
    |> Map.put("signal_id", signal.id)
    |> Map.put("signal_data", signal.data)
  end

  defp subscribe_patterns(bus, patterns) do
    patterns
    |> Enum.reduce_while({:ok, []}, fn pattern, {:ok, subscriptions} ->
      subscribe_pattern(bus, pattern, subscriptions)
    end)
    |> then(fn
      {:ok, subscriptions} -> {:ok, Enum.reverse(subscriptions)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp subscribe_pattern(bus, pattern, subscriptions) do
    case Bus.subscribe(bus, pattern, dispatch: {:pid, target: self()}) do
      {:ok, subscription_id} ->
        {:cont, {:ok, [subscription_id | subscriptions]}}

      {:error, reason} ->
        rollback_subscriptions(bus, subscriptions)
        {:halt, {:error, {:subscribe_failed, pattern, reason}}}
    end
  end

  defp rollback_subscriptions(bus, subscriptions) do
    Enum.each(subscriptions, fn subscription_id ->
      _ = Bus.unsubscribe(bus, subscription_id)
    end)
  end

  defp normalize_backend(value) when value in [:direct, :strategy], do: value
  defp normalize_backend(_value), do: nil

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:invalid_config, field}}

  defp require_patterns([]), do: {:error, {:invalid_config, :patterns}}
  defp require_patterns(_patterns), do: :ok

  defp normalize_patterns(nil), do: []

  defp normalize_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_patterns(pattern) when is_binary(pattern), do: [pattern]
  defp normalize_patterns(_other), do: []

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp via_tuple(id, process_registry) do
    {:via, Elixir.Registry, {process_registry, id}}
  end

  defp default_process_registry do
    Application.get_env(:jido_workflow, :trigger_process_registry, @default_process_registry)
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        fetch_atom_key(map, key)
    end
  end

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, item} ->
      {to_string(key), stringify_keys(item)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
