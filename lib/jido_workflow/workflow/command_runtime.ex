defmodule JidoWorkflow.Workflow.CommandRuntime do
  @moduledoc """
  Handles signal-driven workflow run commands.

  Subscribes to reserved command signals and routes them to the workflow engine:
  - `workflow.run.start.requested`
  - `workflow.run.pause.requested`
  - `workflow.run.resume.requested`
  - `workflow.run.cancel.requested`
  """

  use GenServer

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.RunStore

  @start_requested "workflow.run.start.requested"
  @pause_requested "workflow.run.pause.requested"
  @resume_requested "workflow.run.resume.requested"
  @cancel_requested "workflow.run.cancel.requested"

  @start_accepted "workflow.run.start.accepted"
  @start_rejected "workflow.run.start.rejected"
  @pause_accepted "workflow.run.pause.accepted"
  @pause_rejected "workflow.run.pause.rejected"
  @resume_accepted "workflow.run.resume.accepted"
  @resume_rejected "workflow.run.resume.rejected"
  @cancel_accepted "workflow.run.cancel.accepted"
  @cancel_rejected "workflow.run.cancel.rejected"

  @command_source "/jido_workflow/workflow/commands"

  @type run_task :: %{
          pid: pid(),
          monitor_ref: reference(),
          workflow_id: String.t()
        }

  @type state :: %{
          bus: atom(),
          workflow_registry: GenServer.server(),
          run_store: GenServer.server(),
          backend: Engine.backend() | nil,
          subscription_ids: [String.t()],
          run_tasks: %{String.t() => run_task()},
          run_id_by_monitor_ref: %{reference() => String.t()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :bus, Broadcaster.default_bus())
    workflow_registry = Keyword.get(opts, :workflow_registry, default_workflow_registry())
    run_store = Keyword.get(opts, :run_store, default_run_store())
    backend = normalize_backend(Keyword.get(opts, :backend))

    case subscribe_commands(bus) do
      {:ok, subscription_ids} ->
        {:ok,
         %{
           bus: bus,
           workflow_registry: workflow_registry,
           run_store: run_store,
           backend: backend,
           subscription_ids: subscription_ids,
           run_tasks: %{},
           run_id_by_monitor_ref: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unsubscribe_all(state.bus, state.subscription_ids)
    :ok
  end

  @impl true
  def handle_info({:signal, %Signal{type: @start_requested} = signal}, state) do
    handle_start_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @pause_requested} = signal}, state) do
    handle_pause_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @resume_requested} = signal}, state) do
    handle_resume_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @cancel_requested} = signal}, state) do
    handle_cancel_requested(signal, state)
  end

  def handle_info({:command_run_finished, run_id, _workflow_id, _result}, state) do
    {:noreply, unregister_run_task(state, run_id)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.run_id_by_monitor_ref, monitor_ref) do
      {nil, _remaining} ->
        {:noreply, state}

      {run_id, remaining_by_ref} ->
        next_state = %{
          state
          | run_tasks: Map.delete(state.run_tasks, run_id),
            run_id_by_monitor_ref: remaining_by_ref
        }

        {:noreply, next_state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp handle_start_requested(signal, state) do
    with {:ok, request} <- normalize_start_request(signal.data),
         :ok <- ensure_workflow_exists(request.workflow_id, state.workflow_registry),
         {:ok, run_id, next_state} <- launch_run_task(request, state) do
      _ =
        publish_command_response(
          state.bus,
          @start_accepted,
          %{
            "workflow_id" => request.workflow_id,
            "run_id" => run_id
          },
          signal
        )

      {:noreply, next_state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @start_rejected,
            %{
              "workflow_id" => fetch(signal.data, "workflow_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_pause_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         :ok <- Engine.pause(run_id, run_store: state.run_store, bus: state.bus),
         {:ok, run} <- Engine.get_run(run_id, run_store: state.run_store) do
      _ =
        publish_command_response(
          state.bus,
          @pause_accepted,
          %{
            "workflow_id" => run.workflow_id,
            "run_id" => run.run_id
          },
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @pause_rejected,
            %{
              "run_id" => fetch(signal.data, "run_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_resume_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         :ok <- Engine.resume(run_id, run_store: state.run_store, bus: state.bus),
         {:ok, run} <- Engine.get_run(run_id, run_store: state.run_store) do
      _ =
        publish_command_response(
          state.bus,
          @resume_accepted,
          %{
            "workflow_id" => run.workflow_id,
            "run_id" => run.run_id
          },
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @resume_rejected,
            %{
              "run_id" => fetch(signal.data, "run_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_cancel_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         reason <- fetch_cancel_reason(signal.data),
         :ok <- Engine.cancel(run_id, run_store: state.run_store, bus: state.bus, reason: reason),
         {:ok, run} <- Engine.get_run(run_id, run_store: state.run_store) do
      _ =
        publish_command_response(
          state.bus,
          @cancel_accepted,
          %{
            "workflow_id" => run.workflow_id,
            "run_id" => run.run_id,
            "reason" => format_reason(reason)
          },
          signal
        )

      {:noreply, stop_run_task(state, run_id)}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @cancel_rejected,
            %{
              "run_id" => fetch(signal.data, "run_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp launch_run_task(request, state) do
    run_id = request.run_id || generate_run_id()

    with :ok <- ensure_run_not_registered(state, run_id),
         {:ok, pid} <- start_run_task_process(request, run_id, state) do
      monitor_ref = Process.monitor(pid)
      run_task = %{pid: pid, monitor_ref: monitor_ref, workflow_id: request.workflow_id}

      next_state = %{
        state
        | run_tasks: Map.put(state.run_tasks, run_id, run_task),
          run_id_by_monitor_ref: Map.put(state.run_id_by_monitor_ref, monitor_ref, run_id)
      }

      {:ok, run_id, next_state}
    end
  end

  defp ensure_run_not_registered(state, run_id) do
    if Map.has_key?(state.run_tasks, run_id) do
      {:error, {:run_already_running, run_id}}
    else
      :ok
    end
  end

  defp start_run_task_process(request, run_id, state) do
    opts =
      [
        registry: state.workflow_registry,
        run_store: state.run_store,
        bus: state.bus,
        run_id: run_id
      ]
      |> maybe_put_backend(request.backend || state.backend)

    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        result = Engine.execute(request.workflow_id, request.inputs, opts)
        send(parent, {:command_run_finished, run_id, request.workflow_id, result})
      end)

    {:ok, pid}
  end

  defp stop_run_task(state, run_id) do
    case Map.pop(state.run_tasks, run_id) do
      {nil, _remaining} ->
        state

      {%{pid: pid, monitor_ref: monitor_ref}, remaining_tasks} ->
        if Process.alive?(pid) do
          Process.exit(pid, :kill)
        end

        %{
          state
          | run_tasks: remaining_tasks,
            run_id_by_monitor_ref: Map.delete(state.run_id_by_monitor_ref, monitor_ref)
        }
    end
  end

  defp unregister_run_task(state, run_id) do
    case Map.pop(state.run_tasks, run_id) do
      {nil, _remaining} ->
        state

      {%{monitor_ref: monitor_ref}, remaining_tasks} ->
        %{
          state
          | run_tasks: remaining_tasks,
            run_id_by_monitor_ref: Map.delete(state.run_id_by_monitor_ref, monitor_ref)
        }
    end
  end

  defp subscribe_commands(bus) do
    command_types()
    |> Enum.reduce_while({:ok, []}, fn type, {:ok, subscription_ids} ->
      case Bus.subscribe(bus, type, dispatch: {:pid, target: self()}) do
        {:ok, subscription_id} ->
          {:cont, {:ok, [subscription_id | subscription_ids]}}

        {:error, reason} ->
          unsubscribe_all(bus, subscription_ids)
          {:halt, {:error, {:subscribe_failed, type, reason}}}
      end
    end)
    |> then(fn
      {:ok, subscription_ids} -> {:ok, Enum.reverse(subscription_ids)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp unsubscribe_all(_bus, []), do: :ok

  defp unsubscribe_all(bus, subscription_ids) do
    Enum.each(subscription_ids, fn subscription_id ->
      _ = Bus.unsubscribe(bus, subscription_id)
    end)
  end

  defp ensure_workflow_exists(workflow_id, workflow_registry) do
    case WorkflowRegistry.get_compiled(workflow_id, workflow_registry) do
      {:ok, _compiled} -> :ok
      {:error, reason} -> {:error, {:workflow_not_available, reason}}
    end
  end

  defp normalize_start_request(data) do
    workflow_id = fetch(data, "workflow_id")
    run_id = normalize_optional_binary(fetch(data, "run_id"))
    backend = normalize_backend(fetch(data, "backend"))
    inputs = normalize_start_inputs(data)

    cond do
      not valid_binary?(workflow_id) ->
        {:error, {:missing_or_invalid, :workflow_id}}

      not is_map(inputs) ->
        {:error, {:missing_or_invalid, :inputs}}

      true ->
        {:ok,
         %{
           workflow_id: workflow_id,
           run_id: run_id,
           backend: backend,
           inputs: inputs
         }}
    end
  end

  defp normalize_start_inputs(data) when is_map(data) do
    case fetch(data, "inputs") do
      nil ->
        data
        |> Map.drop(["workflow_id", "run_id", "backend"])
        |> Map.drop([:workflow_id, :run_id, :backend])

      inputs when is_map(inputs) ->
        inputs

      _other ->
        :invalid
    end
  end

  defp normalize_start_inputs(_data), do: :invalid

  defp fetch_required_run_id(data) do
    case fetch(data, "run_id") do
      run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      _ -> {:error, {:missing_or_invalid, :run_id}}
    end
  end

  defp fetch_cancel_reason(data) do
    case fetch(data, "reason") do
      reason when is_binary(reason) and reason != "" -> reason
      reason when is_atom(reason) -> reason
      _ -> :cancelled
    end
  end

  defp publish_command_response(bus, type, payload, request_signal) do
    response =
      payload
      |> maybe_put("requested_signal_id", request_signal.id)
      |> maybe_put("requested_signal_type", request_signal.type)
      |> maybe_put("requested_signal_source", request_signal.source)

    signal = Signal.new!(type, response, source: @command_source)
    Bus.publish(bus, [signal])
  end

  defp command_types do
    [@start_requested, @pause_requested, @resume_requested, @cancel_requested]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_backend(opts, nil), do: opts
  defp maybe_put_backend(opts, backend), do: Keyword.put(opts, :backend, backend)

  defp normalize_backend(value) when value in [:direct, :strategy], do: value

  defp normalize_backend(value) when is_binary(value) do
    case String.downcase(value) do
      "direct" -> :direct
      "strategy" -> :strategy
      _ -> nil
    end
  end

  defp normalize_backend(_value), do: nil

  defp normalize_optional_binary(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_binary(_value), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp valid_binary?(value), do: is_binary(value) and value != ""

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || fetch_atom_key(map, key)
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

  defp default_workflow_registry do
    Application.get_env(:jido_workflow, :workflow_registry, WorkflowRegistry)
  end

  defp default_run_store do
    Application.get_env(:jido_workflow, :run_store, RunStore)
  end

  defp generate_run_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
