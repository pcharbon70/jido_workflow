defmodule JidoWorkflow.Workflow.TriggerSupervisor do
  @moduledoc """
  Dynamic supervisor for workflow trigger processes.

  Supported trigger implementations:
  - `file_system`
  - `git_hook`
  - `scheduled`
  - `signal`
  - `manual`

  Additional trigger types can be registered via
  `JidoWorkflow.Workflow.PluginExtensions.register_trigger_type/2`.
  """

  use DynamicSupervisor

  alias JidoWorkflow.Workflow.Triggers.Manual
  alias JidoWorkflow.Workflow.TriggerTypeRegistry

  @default_process_registry JidoWorkflow.Workflow.TriggerProcessRegistry

  @type trigger_id :: String.t()
  @type trigger_config :: map()
  @type manual_lookup_opts :: [workflow_id: String.t()] | keyword()

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

  @spec lookup_manual_by_command(String.t(), manual_lookup_opts()) ::
          {:ok, trigger_id()} | {:error, term()}
  def lookup_manual_by_command(command, opts \\ []) when is_binary(command) do
    workflow_id = Keyword.get(opts, :workflow_id)

    with {:ok, match} <- find_manual_match(command, workflow_id, opts) do
      {:ok, match.id}
    end
  end

  @spec trigger_manual_by_command(String.t(), map(), manual_lookup_opts()) ::
          {:ok, JidoWorkflow.Workflow.Engine.execution_result()} | {:error, term()}
  def trigger_manual_by_command(command, params \\ %{}, opts \\ [])

  def trigger_manual_by_command(command, params, opts)
      when is_binary(command) and is_map(params) do
    with {:ok, trigger_id} <- lookup_manual_by_command(command, opts) do
      trigger_manual(trigger_id, params, opts)
    end
  end

  defp trigger_module(config) do
    case TriggerTypeRegistry.resolve(fetch(config, "type")) do
      {:ok, module} ->
        {:ok, module}

      {:error, {:unsupported_trigger_type, type}} ->
        {:error, {:unsupported_trigger_type, type}}
    end
  end

  defp process_registry(opts) do
    Keyword.get_lazy(opts, :process_registry, fn ->
      Application.get_env(:jido_workflow, :trigger_process_registry, @default_process_registry)
    end)
  end

  defp find_manual_match(command, workflow_id, opts) do
    matches =
      opts
      |> process_registry()
      |> manual_trigger_matches(command, workflow_id)

    case matches do
      [match] ->
        {:ok, match}

      [] ->
        {:error, :not_found}

      many ->
        {:error, {:ambiguous_manual_command, Enum.map(many, & &1.id)}}
    end
  end

  defp manual_trigger_matches(process_registry, command, workflow_id) do
    list_trigger_ids(process_registry: process_registry)
    |> Enum.reduce([], fn trigger_id, acc ->
      append_manual_match(acc, trigger_id, process_registry, command, workflow_id)
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp append_manual_match(acc, trigger_id, process_registry, command, workflow_id) do
    with [{pid, value}] <- Registry.lookup(process_registry, trigger_id),
         true <- manual_trigger_match?(pid, value, command, workflow_id) do
      [
        %{
          id: trigger_id,
          pid: pid,
          workflow_id: fetch_value(value, "workflow_id"),
          command: fetch_value(value, "command")
        }
        | acc
      ]
    else
      _other -> acc
    end
  end

  defp manual_trigger_match?(pid, value, command, workflow_id) do
    Process.alive?(pid) and manual_trigger_value?(value) and
      command_match?(fetch_value(value, "command"), command) and
      workflow_match?(fetch_value(value, "workflow_id"), workflow_id)
  end

  defp manual_trigger_value?(value) when is_map(value) do
    fetch_value(value, "trigger_type") == "manual"
  end

  defp manual_trigger_value?(_value), do: false

  defp command_match?(configured, requested)
       when is_binary(configured) and configured != "" and is_binary(requested) and
              requested != "" do
    configured == requested
  end

  defp command_match?(_configured, _requested), do: false

  defp workflow_match?(_configured, nil), do: true
  defp workflow_match?("", _workflow_id), do: false
  defp workflow_match?(nil, _workflow_id), do: false

  defp workflow_match?(configured, requested)
       when is_binary(configured) and is_binary(requested) do
    configured == requested
  end

  defp workflow_match?(_configured, _requested), do: false

  defp fetch_value(value, key) when is_map(value) do
    Map.get(value, key) || fetch_atom_key(value, key)
  end

  defp fetch_value(_value, _key), do: nil

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
