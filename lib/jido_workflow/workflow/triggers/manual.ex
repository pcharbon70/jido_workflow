defmodule JidoWorkflow.Workflow.Triggers.Manual do
  @moduledoc """
  Manual trigger process.

  Exposes `trigger/2` to run the configured workflow on demand.
  """

  use GenServer

  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry

  @default_process_registry JidoWorkflow.Workflow.TriggerProcessRegistry

  @type state :: %{
          id: String.t(),
          workflow_id: String.t(),
          command: String.t() | nil,
          workflow_registry: GenServer.server(),
          bus: atom(),
          backend: Engine.backend() | nil
        }

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) when is_map(config) do
    process_registry = fetch(config, "process_registry") || default_process_registry()
    id = fetch(config, "id")

    GenServer.start_link(__MODULE__, config, name: via_tuple(id, process_registry))
  end

  @spec trigger(GenServer.server(), map()) ::
          {:ok, Engine.execution_result()} | {:error, term()}
  def trigger(server, params \\ %{}) when is_map(params) do
    GenServer.call(server, {:trigger, params})
  end

  @impl true
  def init(config) do
    id = fetch(config, "id")
    workflow_id = fetch(config, "workflow_id")
    command = fetch(config, "command")

    workflow_registry =
      fetch(config, "workflow_registry") || fetch(config, "registry") || WorkflowRegistry

    bus = fetch(config, "bus") || Broadcaster.default_bus()
    backend = normalize_backend(fetch(config, "backend"))

    with :ok <- require_binary(id, :id),
         :ok <- require_binary(workflow_id, :workflow_id) do
      {:ok,
       %{
         id: id,
         workflow_id: workflow_id,
         command: command,
         workflow_registry: workflow_registry,
         bus: bus,
         backend: backend
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:trigger, params}, _from, state) do
    payload =
      params
      |> stringify_keys()
      |> Map.put("trigger_type", "manual")
      |> Map.put("trigger_id", state.id)
      |> Map.put("triggered_at", timestamp())
      |> maybe_put_command(state.command)

    opts =
      [registry: state.workflow_registry, bus: state.bus]
      |> maybe_put_backend(state.backend)

    {:reply, Engine.execute(state.workflow_id, payload, opts), state}
  end

  defp maybe_put_command(payload, nil), do: payload
  defp maybe_put_command(payload, command), do: Map.put(payload, "command", command)

  defp maybe_put_backend(opts, nil), do: opts
  defp maybe_put_backend(opts, backend), do: Keyword.put(opts, :backend, backend)

  defp normalize_backend(value) when value in [:direct, :strategy], do: value
  defp normalize_backend(_value), do: nil

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, {:invalid_config, field}}

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
