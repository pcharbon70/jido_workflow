defmodule Jido.Code.Workflow.TriggerSupervisor do
  @moduledoc """
  Dynamic supervisor for workflow trigger processes.

  Supported trigger implementations:
  - `file_system`
  - `git_hook`
  - `scheduled`
  - `signal`
  - `manual`

  Additional trigger types can be registered via
  `Jido.Code.Workflow.PluginExtensions.register_trigger_type/2`.
  """

  use DynamicSupervisor

  alias Jido.Code.Workflow.Triggers.Manual
  alias Jido.Code.Workflow.TriggerTypeRegistry

  @default_process_registry Jido.Code.Workflow.TriggerProcessRegistry

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

  @spec list_trigger_statuses(keyword()) :: [map()]
  def list_trigger_statuses(opts \\ []) do
    process_registry = process_registry(opts)

    list_trigger_ids(process_registry: process_registry)
    |> Enum.map(fn trigger_id ->
      case Registry.lookup(process_registry, trigger_id) do
        [{pid, registry_value}] ->
          build_trigger_status(trigger_id, pid, registry_value)

        [] ->
          %{
            id: trigger_id,
            alive?: false,
            reason: :not_found
          }
      end
    end)
  end

  @spec trigger_manual(trigger_id(), map(), keyword()) ::
          {:ok, Jido.Code.Workflow.Engine.execution_result()} | {:error, term()}
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
    case normalize_lookup_string(command) do
      nil ->
        {:error, :not_found}

      command ->
        workflow_id = normalize_lookup_string(Keyword.get(opts, :workflow_id))

        with {:ok, match} <- find_manual_match(command, workflow_id, opts) do
          {:ok, match.id}
        end
    end
  end

  @spec trigger_manual_by_command(String.t(), map(), manual_lookup_opts()) ::
          {:ok, Jido.Code.Workflow.Engine.execution_result()} | {:error, term()}
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

  defp build_trigger_status(trigger_id, pid, registry_value) do
    case safe_get_state(pid) do
      {:ok, state} ->
        state_map = normalize_state_map(state)

        status =
          %{
            id: trigger_id,
            pid: pid,
            alive?: Process.alive?(pid),
            trigger_type: trigger_type(state_map, registry_value),
            workflow_id: state_value(state_map, :workflow_id)
          }
          |> maybe_put_status(:backend, state_value(state_map, :backend))
          |> maybe_put_status(:bus, state_value(state_map, :bus))
          |> maybe_put_status(:command, state_value(state_map, :command))
          |> maybe_put_status(:patterns, state_value(state_map, :patterns))
          |> maybe_put_status(:schedule, state_value(state_map, :schedule))
          |> maybe_put_status(:next_run_at, state_value(state_map, :next_run_at))
          |> maybe_put_status(:root_dir, state_value(state_map, :root_dir))
          |> maybe_put_status(:repo_path, state_value(state_map, :repo_path))
          |> maybe_put_status(:events, state_value(state_map, :events))
          |> maybe_put_status(:debounce_ms, state_value(state_map, :debounce_ms))
          |> maybe_put_status(
            :subscription_count,
            list_count(state_value(state_map, :subscription_ids))
          )
          |> maybe_put_status(
            :pending_paths,
            map_size_or_nil(state_value(state_map, :pending_events))
          )
          |> maybe_put_status(:watcher_alive?, alive_pid?(state_value(state_map, :watcher_pid)))
          |> maybe_put_status(:timer_active?, not is_nil(state_value(state_map, :timer_ref)))

        status

      {:error, reason} ->
        %{
          id: trigger_id,
          pid: pid,
          alive?: Process.alive?(pid),
          trigger_type: trigger_type(%{}, registry_value),
          workflow_id: fetch_value(registry_value, "workflow_id"),
          reason: {:state_unavailable, reason}
        }
    end
  end

  defp safe_get_state(pid) when is_pid(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp normalize_state_map(value) when is_map(value), do: value
  defp normalize_state_map(_value), do: %{}

  defp trigger_type(state, registry_value) do
    state_value(state, :type) || fetch_value(registry_value, "trigger_type")
  end

  defp state_value(state, key) when is_map(state) do
    Map.get(state, key) || Map.get(state, to_string(key)) || fetch_atom_key(state, to_string(key))
  end

  defp maybe_put_status(map, _key, nil), do: map

  defp maybe_put_status(map, key, value) do
    Map.put(map, key, normalize_status_value(value))
  end

  defp normalize_status_value(%MapSet{} = value), do: value |> MapSet.to_list() |> Enum.sort()
  defp normalize_status_value(value), do: value

  defp list_count(values) when is_list(values), do: length(values)
  defp list_count(_values), do: nil

  defp map_size_or_nil(values) when is_map(values), do: map_size(values)
  defp map_size_or_nil(_values), do: nil

  defp alive_pid?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp alive_pid?(_other), do: nil

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

  defp normalize_lookup_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_lookup_string(_value), do: nil

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
