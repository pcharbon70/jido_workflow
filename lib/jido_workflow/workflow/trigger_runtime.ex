defmodule JidoWorkflow.Workflow.TriggerRuntime do
  @moduledoc """
  Orchestrates trigger lifecycle synchronization from workflow definitions.

  Responsibilities:
  - refresh workflow registry snapshots
  - sync trigger processes with current workflow triggers
  - optionally perform periodic refresh+sync
  """

  use GenServer

  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.TriggerManager
  alias JidoWorkflow.Workflow.TriggerSupervisor

  @type refresh_result :: {:ok, %{registry: map(), triggers: TriggerManager.sync_summary()}}
  @type sync_result :: {:ok, TriggerManager.sync_summary()}
  @type runtime_result :: refresh_result() | sync_result() | {:error, term()}

  @type state :: %{
          workflow_registry: GenServer.server(),
          trigger_supervisor: GenServer.server(),
          process_registry: atom(),
          bus: atom(),
          triggers_config_path: Path.t() | nil,
          backend: :direct | :strategy | nil,
          sync_interval_ms: pos_integer() | nil,
          timer_ref: reference() | nil,
          last_result: runtime_result() | nil,
          last_error: term() | nil,
          last_sync_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec refresh(GenServer.server()) :: runtime_result()
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @spec sync(GenServer.server()) :: runtime_result()
  def sync(server \\ __MODULE__) do
    GenServer.call(server, :sync)
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    state =
      opts
      |> build_state()
      |> schedule_periodic_sync()

    if Keyword.get(opts, :sync_on_start, true) do
      send(self(), :initial_refresh_sync)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    {result, next_state} = do_refresh_and_sync(state)
    {:reply, result, next_state}
  end

  def handle_call(:sync, _from, state) do
    {result, next_state} = do_sync_only(state)
    {:reply, result, next_state}
  end

  def handle_call(:status, _from, state) do
    {:reply, status_payload(state), state}
  end

  @impl true
  def handle_info(:initial_refresh_sync, state) do
    {_result, next_state} = do_refresh_and_sync(state)
    {:noreply, next_state}
  end

  def handle_info(:periodic_refresh_sync, state) do
    {_result, next_state} =
      state
      |> clear_timer()
      |> do_refresh_and_sync()

    {:noreply, schedule_periodic_sync(next_state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp build_state(opts) do
    %{
      workflow_registry: Keyword.get(opts, :workflow_registry, default_workflow_registry()),
      trigger_supervisor: Keyword.get(opts, :trigger_supervisor, default_trigger_supervisor()),
      process_registry: Keyword.get(opts, :process_registry, default_process_registry()),
      bus: Keyword.get(opts, :bus, Broadcaster.default_bus()),
      triggers_config_path:
        Keyword.get(opts, :triggers_config_path, default_triggers_config_path()),
      backend: normalize_backend(Keyword.get(opts, :backend)),
      sync_interval_ms:
        normalize_interval(Keyword.get(opts, :sync_interval_ms, default_sync_interval_ms())),
      timer_ref: nil,
      last_result: nil,
      last_error: nil,
      last_sync_at: nil
    }
  end

  defp do_refresh_and_sync(state) do
    with {:ok, registry_summary} <- WorkflowRegistry.refresh(state.workflow_registry),
         {:ok, trigger_summary} <- sync_triggers(state) do
      result = {:ok, %{registry: registry_summary, triggers: trigger_summary}}
      {result, record_result(state, result)}
    else
      {:error, reason} = error ->
        {error, record_result(state, {:error, reason})}
    end
  end

  defp do_sync_only(state) do
    case sync_triggers(state) do
      {:ok, trigger_summary} = ok ->
        {ok, record_result(state, {:ok, trigger_summary})}

      {:error, reason} = error ->
        {error, record_result(state, {:error, reason})}
    end
  end

  defp sync_triggers(state) do
    TriggerManager.sync_from_registry(
      workflow_registry: state.workflow_registry,
      trigger_supervisor: state.trigger_supervisor,
      process_registry: state.process_registry,
      bus: state.bus,
      triggers_config_path: state.triggers_config_path,
      backend: state.backend
    )
  end

  defp record_result(state, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case result do
      {:error, reason} ->
        %{state | last_result: result, last_error: reason, last_sync_at: now}

      _ ->
        %{state | last_result: result, last_error: nil, last_sync_at: now}
    end
  end

  defp status_payload(state) do
    %{
      workflow_registry: state.workflow_registry,
      trigger_supervisor: state.trigger_supervisor,
      process_registry: state.process_registry,
      bus: state.bus,
      triggers_config_path: state.triggers_config_path,
      backend: state.backend,
      sync_interval_ms: state.sync_interval_ms,
      trigger_ids: TriggerSupervisor.list_trigger_ids(process_registry: state.process_registry),
      last_result: state.last_result,
      last_error: state.last_error,
      last_sync_at: state.last_sync_at
    }
  end

  defp schedule_periodic_sync(%{sync_interval_ms: nil} = state), do: state

  defp schedule_periodic_sync(%{sync_interval_ms: interval_ms} = state) do
    state = cancel_timer(state)
    timer_ref = Process.send_after(self(), :periodic_refresh_sync, interval_ms)
    %{state | timer_ref: timer_ref}
  end

  defp clear_timer(state), do: %{state | timer_ref: nil}

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | timer_ref: nil}
  end

  defp normalize_backend(value) when value in [:direct, :strategy], do: value
  defp normalize_backend(_value), do: nil

  defp normalize_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_interval(_value), do: nil

  defp default_workflow_registry do
    Application.get_env(:jido_workflow, :workflow_registry, WorkflowRegistry)
  end

  defp default_trigger_supervisor do
    Application.get_env(:jido_workflow, :trigger_supervisor, TriggerSupervisor)
  end

  defp default_process_registry do
    Application.get_env(
      :jido_workflow,
      :trigger_process_registry,
      JidoWorkflow.Workflow.TriggerProcessRegistry
    )
  end

  defp default_sync_interval_ms do
    Application.get_env(:jido_workflow, :trigger_sync_interval_ms)
  end

  defp default_triggers_config_path do
    Application.get_env(
      :jido_workflow,
      :triggers_config_path,
      ".jido_code/workflows/triggers.json"
    )
  end
end
