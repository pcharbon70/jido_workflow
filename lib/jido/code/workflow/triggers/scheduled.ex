defmodule Jido.Code.Workflow.Triggers.Scheduled do
  @moduledoc """
  Scheduled trigger process.

  Executes workflows on cron schedules using `Crontab`.
  """

  use GenServer

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler
  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Code.Workflow.Engine
  alias Jido.Code.Workflow.Registry, as: WorkflowRegistry

  @max_schedule_search_runs 100_000
  @default_process_registry Jido.Code.Workflow.TriggerProcessRegistry

  @type state :: %{
          id: String.t(),
          workflow_id: String.t(),
          schedule: String.t(),
          cron_expression: CronExpression.t(),
          params: map(),
          workflow_registry: GenServer.server(),
          bus: atom(),
          backend: Engine.backend() | nil,
          timer_ref: reference() | nil,
          next_run_at: DateTime.t() | nil
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
    schedule = fetch(config, "schedule")
    params = normalize_params(fetch(config, "params"))

    workflow_registry =
      fetch(config, "workflow_registry") || fetch(config, "registry") || WorkflowRegistry

    bus = fetch(config, "bus") || Broadcaster.default_bus()
    backend = normalize_backend(fetch(config, "backend"))

    with :ok <- require_binary(id, :id),
         :ok <- require_binary(workflow_id, :workflow_id),
         :ok <- require_binary(schedule, :schedule),
         {:ok, cron_expression} <- parse_schedule(schedule),
         {:ok, state} <-
           schedule_next_run(%{
             id: id,
             workflow_id: workflow_id,
             schedule: schedule,
             cron_expression: cron_expression,
             params: params,
             workflow_registry: workflow_registry,
             bus: bus,
             backend: backend,
             timer_ref: nil,
             next_run_at: nil
           }) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:run_scheduled_workflow, state) do
    payload = scheduled_payload(state)
    _ = execute_workflow(state, payload)

    state = %{state | timer_ref: nil, next_run_at: nil}

    case schedule_next_run(state) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.timer_ref)
    :ok
  end

  defp schedule_next_run(state) do
    now = DateTime.utc_now()

    case next_run_at(state.cron_expression, now) do
      {:ok, next_run_at} ->
        delay_ms = max(DateTime.diff(next_run_at, now, :millisecond), 0)

        cancel_timer(state.timer_ref)
        timer_ref = Process.send_after(self(), :run_scheduled_workflow, delay_ms)

        {:ok, %{state | timer_ref: timer_ref, next_run_at: next_run_at}}

      {:error, reason} ->
        {:error, {:schedule_next_run_failed, reason}}
    end
  end

  defp next_run_at(cron_expression, now) do
    with {:ok, next_run_naive} <-
           CronScheduler.get_next_run_date(
             cron_expression,
             DateTime.to_naive(now),
             @max_schedule_search_runs
           ) do
      case DateTime.from_naive(next_run_naive, "Etc/UTC") do
        {:ok, next_run_at} -> {:ok, next_run_at}
        {:ambiguous, first, _second} -> {:ok, first}
        {:gap, _before, _after} -> {:error, :invalid_next_run_datetime}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp execute_workflow(state, payload) do
    opts =
      [registry: state.workflow_registry, bus: state.bus]
      |> maybe_put_backend(state.backend)

    Engine.execute(state.workflow_id, payload, opts)
  end

  defp scheduled_payload(state) do
    state.params
    |> stringify_keys()
    |> Map.put("trigger_type", "scheduled")
    |> Map.put("trigger_id", state.id)
    |> Map.put("triggered_at", timestamp())
    |> Map.put("schedule", state.schedule)
    |> maybe_put_scheduled_for(state.next_run_at)
  end

  defp maybe_put_scheduled_for(payload, nil), do: payload

  defp maybe_put_scheduled_for(payload, %DateTime{} = scheduled_for) do
    Map.put(payload, "scheduled_for", DateTime.to_iso8601(scheduled_for))
  end

  defp parse_schedule(schedule) when is_binary(schedule) do
    extended? = extended_schedule?(schedule)

    case CronParser.parse(schedule, extended?) do
      {:ok, %CronExpression{reboot: true}} ->
        {:error, {:invalid_schedule, "@reboot is not supported"}}

      {:ok, %CronExpression{} = cron_expression} ->
        {:ok, cron_expression}

      {:error, reason} ->
        {:error, {:invalid_schedule, reason}}
    end
  end

  defp extended_schedule?(schedule) do
    schedule
    |> String.split(~r/\s+/, trim: true)
    |> length()
    |> Kernel.>=(6)
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_other), do: %{}

  defp maybe_put_backend(opts, nil), do: opts
  defp maybe_put_backend(opts, backend), do: Keyword.put(opts, :backend, backend)

  defp normalize_backend(value) when value in [:direct, :strategy], do: value
  defp normalize_backend(_value), do: nil

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

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
