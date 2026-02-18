defmodule JidoWorkflow.Workflow.TriggerSupervisor do
  @moduledoc """
  Dynamic supervisor for workflow trigger processes.

  Supported trigger implementations:
  - `file_system`
  - `scheduled`
  - `signal`
  - `manual`
  """

  use DynamicSupervisor

  alias JidoWorkflow.Workflow.Triggers.FileSystem
  alias JidoWorkflow.Workflow.Triggers.Manual
  alias JidoWorkflow.Workflow.Triggers.Scheduled
  alias JidoWorkflow.Workflow.Triggers.Signal

  @default_process_registry JidoWorkflow.Workflow.TriggerProcessRegistry

  @type trigger_id :: String.t()
  @type trigger_config :: map()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_trigger(trigger_config(), keyword()) ::
          DynamicSupervisor.on_start_child() | {:error, term()}
  def start_trigger(config, opts \\ []) when is_map(config) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    with {:ok, module} <- trigger_module(config) do
      config = Map.put_new(config, :process_registry, process_registry(opts))
      DynamicSupervisor.start_child(supervisor, {module, config})
    end
  end

  @spec stop_trigger(trigger_id(), keyword()) :: :ok | {:error, term()}
  def stop_trigger(trigger_id, opts \\ []) when is_binary(trigger_id) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    with {:ok, pid} <- lookup_trigger(trigger_id, opts) do
      DynamicSupervisor.terminate_child(supervisor, pid)
    end
  end

  @spec lookup_trigger(trigger_id(), keyword()) :: {:ok, pid()} | {:error, :not_found}
  def lookup_trigger(trigger_id, opts \\ []) when is_binary(trigger_id) do
    case Registry.lookup(process_registry(opts), trigger_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @spec list_trigger_ids(keyword()) :: [trigger_id()]
  def list_trigger_ids(opts \\ []) do
    process_registry(opts)
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec trigger_manual(trigger_id(), map(), keyword()) ::
          {:ok, JidoWorkflow.Workflow.Engine.execution_result()} | {:error, term()}
  def trigger_manual(trigger_id, params \\ %{}, opts \\ [])

  def trigger_manual(trigger_id, params, opts)
      when is_binary(trigger_id) and is_map(params) do
    with {:ok, pid} <- lookup_trigger(trigger_id, opts) do
      Manual.trigger(pid, params)
    end
  end

  defp trigger_module(config) do
    case fetch(config, "type") do
      "file_system" -> {:ok, FileSystem}
      "scheduled" -> {:ok, Scheduled}
      "signal" -> {:ok, Signal}
      "manual" -> {:ok, Manual}
      type -> {:error, {:unsupported_trigger_type, type}}
    end
  end

  defp process_registry(opts) do
    Keyword.get_lazy(opts, :process_registry, fn ->
      Application.get_env(:jido_workflow, :trigger_process_registry, @default_process_registry)
    end)
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
end
