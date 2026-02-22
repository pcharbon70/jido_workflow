defmodule JidoWorkflow.Workflow.CommandRuntime do
  @moduledoc """
  Handles signal-driven workflow run commands.

  Subscribes to reserved command signals and routes them to the workflow engine:
  - `workflow.run.start.requested`
  - `workflow.run.pause.requested`
  - `workflow.run.step.requested`
  - `workflow.run.mode.requested`
  - `workflow.run.resume.requested`
  - `workflow.run.cancel.requested`
  - `workflow.run.get.requested`
  - `workflow.run.list.requested`
  - `workflow.runtime.status.requested`
  - `workflow.definition.list.requested`
  - `workflow.definition.get.requested`
  - `workflow.registry.refresh.requested`
  - `workflow.registry.reload.requested`
  - `workflow.trigger.manual.requested`
  - `workflow.trigger.refresh.requested`
  - `workflow.trigger.sync.requested`
  - `workflow.trigger.runtime.status.requested`
  """

  use GenServer
  require Logger

  alias Jido.Signal
  alias Jido.Signal.Bus
  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.Registry, as: WorkflowRegistry
  alias JidoWorkflow.Workflow.RunStore
  alias JidoWorkflow.Workflow.TriggerRuntime
  alias JidoWorkflow.Workflow.TriggerSupervisor

  @start_requested "workflow.run.start.requested"
  @pause_requested "workflow.run.pause.requested"
  @step_requested "workflow.run.step.requested"
  @mode_requested "workflow.run.mode.requested"
  @resume_requested "workflow.run.resume.requested"
  @cancel_requested "workflow.run.cancel.requested"
  @get_requested "workflow.run.get.requested"
  @list_requested "workflow.run.list.requested"
  @runtime_status_requested "workflow.runtime.status.requested"
  @definition_list_requested "workflow.definition.list.requested"
  @definition_get_requested "workflow.definition.get.requested"
  @registry_refresh_requested "workflow.registry.refresh.requested"
  @registry_reload_requested "workflow.registry.reload.requested"
  @manual_trigger_requested "workflow.trigger.manual.requested"
  @trigger_refresh_requested "workflow.trigger.refresh.requested"
  @trigger_sync_requested "workflow.trigger.sync.requested"
  @trigger_runtime_status_requested "workflow.trigger.runtime.status.requested"

  @start_accepted "workflow.run.start.accepted"
  @start_rejected "workflow.run.start.rejected"
  @pause_accepted "workflow.run.pause.accepted"
  @pause_rejected "workflow.run.pause.rejected"
  @step_accepted "workflow.run.step.accepted"
  @step_rejected "workflow.run.step.rejected"
  @mode_accepted "workflow.run.mode.accepted"
  @mode_rejected "workflow.run.mode.rejected"
  @resume_accepted "workflow.run.resume.accepted"
  @resume_rejected "workflow.run.resume.rejected"
  @cancel_accepted "workflow.run.cancel.accepted"
  @cancel_rejected "workflow.run.cancel.rejected"
  @get_accepted "workflow.run.get.accepted"
  @get_rejected "workflow.run.get.rejected"
  @list_accepted "workflow.run.list.accepted"
  @list_rejected "workflow.run.list.rejected"
  @runtime_status_accepted "workflow.runtime.status.accepted"
  @definition_list_accepted "workflow.definition.list.accepted"
  @definition_list_rejected "workflow.definition.list.rejected"
  @definition_get_accepted "workflow.definition.get.accepted"
  @definition_get_rejected "workflow.definition.get.rejected"
  @registry_refresh_accepted "workflow.registry.refresh.accepted"
  @registry_refresh_rejected "workflow.registry.refresh.rejected"
  @registry_reload_accepted "workflow.registry.reload.accepted"
  @registry_reload_rejected "workflow.registry.reload.rejected"
  @manual_trigger_accepted "workflow.trigger.manual.accepted"
  @manual_trigger_rejected "workflow.trigger.manual.rejected"
  @trigger_refresh_accepted "workflow.trigger.refresh.accepted"
  @trigger_refresh_rejected "workflow.trigger.refresh.rejected"
  @trigger_sync_accepted "workflow.trigger.sync.accepted"
  @trigger_sync_rejected "workflow.trigger.sync.rejected"
  @trigger_runtime_status_accepted "workflow.trigger.runtime.status.accepted"
  @trigger_runtime_status_rejected "workflow.trigger.runtime.status.rejected"

  @command_source "/jido_workflow/workflow/commands"

  @type run_task :: %{
          pid: pid(),
          monitor_ref: reference(),
          workflow_id: String.t(),
          backend: Engine.backend() | nil,
          runtime_agent_pid: pid() | nil
        }

  @type state :: %{
          bus: atom(),
          workflow_registry: GenServer.server(),
          run_store: GenServer.server(),
          trigger_supervisor: GenServer.server(),
          trigger_process_registry: atom(),
          trigger_runtime: GenServer.server(),
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

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @impl true
  def init(opts) do
    bus = Keyword.get(opts, :bus, Broadcaster.default_bus())
    workflow_registry = Keyword.get(opts, :workflow_registry, default_workflow_registry())
    run_store = Keyword.get(opts, :run_store, default_run_store())
    trigger_supervisor = Keyword.get(opts, :trigger_supervisor, default_trigger_supervisor())

    trigger_process_registry =
      Keyword.get(opts, :trigger_process_registry, default_trigger_process_registry())

    trigger_runtime = Keyword.get(opts, :trigger_runtime, default_trigger_runtime())

    backend = normalize_backend(Keyword.get(opts, :backend))

    case subscribe_commands(bus) do
      {:ok, subscription_ids} ->
        {:ok,
         %{
           bus: bus,
           workflow_registry: workflow_registry,
           run_store: run_store,
           trigger_supervisor: trigger_supervisor,
           trigger_process_registry: trigger_process_registry,
           trigger_runtime: trigger_runtime,
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
    _ = stop_all_run_tasks(state)
    unsubscribe_all(state.bus, state.subscription_ids)
    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_payload(state), state}
  end

  @impl true
  def handle_info({:signal, %Signal{type: @start_requested} = signal}, state) do
    handle_start_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @pause_requested} = signal}, state) do
    handle_pause_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @step_requested} = signal}, state) do
    handle_step_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @mode_requested} = signal}, state) do
    handle_mode_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @resume_requested} = signal}, state) do
    handle_resume_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @cancel_requested} = signal}, state) do
    handle_cancel_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @get_requested} = signal}, state) do
    handle_get_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @list_requested} = signal}, state) do
    handle_list_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @runtime_status_requested} = signal}, state) do
    handle_runtime_status_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @definition_list_requested} = signal}, state) do
    handle_definition_list_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @definition_get_requested} = signal}, state) do
    handle_definition_get_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @registry_refresh_requested} = signal}, state) do
    handle_registry_refresh_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @registry_reload_requested} = signal}, state) do
    handle_registry_reload_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @manual_trigger_requested} = signal}, state) do
    handle_manual_trigger_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @trigger_refresh_requested} = signal}, state) do
    handle_trigger_refresh_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @trigger_sync_requested} = signal}, state) do
    handle_trigger_sync_requested(signal, state)
  end

  def handle_info({:signal, %Signal{type: @trigger_runtime_status_requested} = signal}, state) do
    handle_trigger_runtime_status_requested(signal, state)
  end

  def handle_info({:command_run_runtime_agent_started, run_id, runtime_agent_pid}, state) do
    {:noreply, register_runtime_agent(state, run_id, runtime_agent_pid)}
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
              "workflow_id" => fetch_requested_workflow_id(signal.data),
              "reason" => format_reason(reason)
            }
            |> maybe_put("run_id", fetch_normalized_binary(signal.data, "run_id")),
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_manual_trigger_requested(signal, state) do
    with {:ok, request} <- normalize_manual_trigger_request(signal.data),
         {:ok, trigger_id, execution} <- execute_manual_trigger_request(request, state) do
      _ =
        publish_command_response(
          state.bus,
          @manual_trigger_accepted,
          %{
            "trigger_id" => trigger_id,
            "workflow_id" => execution.workflow_id,
            "run_id" => execution.run_id,
            "status" => to_string(execution.status)
          }
          |> maybe_put("command", request.command),
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @manual_trigger_rejected,
            %{
              "trigger_id" => fetch_normalized_binary(signal.data, "trigger_id"),
              "workflow_id" => fetch_requested_workflow_id(signal.data),
              "command" => fetch_normalized_binary(signal.data, "command"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_trigger_refresh_requested(signal, state) do
    case refresh_trigger_runtime(state.trigger_runtime) do
      {:ok, refresh_summary} ->
        _ =
          publish_command_response(
            state.bus,
            @trigger_refresh_accepted,
            %{"summary" => to_signal_value(refresh_summary)},
            signal
          )

        {:noreply, state}

      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @trigger_refresh_rejected,
            %{"reason" => format_reason(reason)},
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_trigger_sync_requested(signal, state) do
    case sync_trigger_runtime(state.trigger_runtime) do
      {:ok, sync_summary} ->
        _ =
          publish_command_response(
            state.bus,
            @trigger_sync_accepted,
            %{"summary" => to_signal_value(sync_summary)},
            signal
          )

        {:noreply, state}

      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @trigger_sync_rejected,
            %{"reason" => format_reason(reason)},
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_trigger_runtime_status_requested(signal, state) do
    case trigger_runtime_status(state.trigger_runtime) do
      {:ok, status} ->
        _ =
          publish_command_response(
            state.bus,
            @trigger_runtime_status_accepted,
            %{"status" => to_signal_value(status)},
            signal
          )

        {:noreply, state}

      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @trigger_runtime_status_rejected,
            %{"reason" => format_reason(reason)},
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_pause_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         :ok <- maybe_pause_strategy_runtime(state, run_id),
         :ok <- pause_run(run_id, state),
         {:ok, run} <- get_run(run_id, state) do
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
              "run_id" => fetch_normalized_binary(signal.data, "run_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_step_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         {:ok, run} <- get_run(run_id, state),
         :ok <- ensure_active_run_status(run),
         {:ok, runtime_agent_pid} <- fetch_strategy_runtime_agent(state, run_id, run),
         :ok <-
           send_runtime_signal(
             runtime_agent_pid,
             "runic.step",
             %{},
             runtime_source(run_id, "step")
           ) do
      _ =
        publish_command_response(
          state.bus,
          @step_accepted,
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
            @step_rejected,
            %{
              "run_id" => fetch_normalized_binary(signal.data, "run_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_mode_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         {:ok, mode} <- fetch_required_mode(signal.data),
         {:ok, run} <- get_run(run_id, state),
         :ok <- ensure_active_run_status(run),
         {:ok, runtime_agent_pid} <- fetch_strategy_runtime_agent(state, run_id, run),
         :ok <-
           send_runtime_signal(
             runtime_agent_pid,
             "runic.set_mode",
             %{mode: mode},
             runtime_source(run_id, "mode")
           ),
         {:ok, run_after_mode} <- apply_run_mode_transition(mode, run, state) do
      _ =
        publish_command_response(
          state.bus,
          @mode_accepted,
          %{
            "workflow_id" => run_after_mode.workflow_id,
            "run_id" => run_after_mode.run_id,
            "mode" => Atom.to_string(mode),
            "status" => Atom.to_string(run_after_mode.status)
          },
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @mode_rejected,
            %{
              "run_id" => fetch_normalized_binary(signal.data, "run_id"),
              "mode" => fetch_requested_mode(signal.data),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_resume_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         :ok <- maybe_resume_strategy_runtime(state, run_id),
         :ok <- resume_run(run_id, state),
         {:ok, run} <- get_run(run_id, state) do
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
              "run_id" => fetch_normalized_binary(signal.data, "run_id"),
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
         :ok <- maybe_stop_strategy_runtime(state, run_id),
         :ok <- cancel_run(run_id, reason, state),
         {:ok, run} <- get_run(run_id, state) do
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
              "run_id" => fetch_normalized_binary(signal.data, "run_id"),
              "reason" => format_reason(reason)
            }
            |> maybe_put("requested_reason", fetch_requested_cancel_reason(signal.data)),
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_get_requested(signal, state) do
    with {:ok, run_id} <- fetch_required_run_id(signal.data),
         {:ok, run} <- get_run(run_id, state) do
      _ =
        publish_command_response(
          state.bus,
          @get_accepted,
          %{"run" => serialize_run(run)},
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @get_rejected,
            %{
              "run_id" => fetch_normalized_binary(signal.data, "run_id"),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_list_requested(signal, state) do
    case normalize_list_opts(signal.data) do
      {:ok, list_opts} ->
        case list_runs(list_opts, state) do
          {:ok, runs} ->
            _ =
              publish_command_response(
                state.bus,
                @list_accepted,
                %{"runs" => Enum.map(runs, &serialize_run/1), "count" => length(runs)},
                signal
              )

            {:noreply, state}

          {:error, reason} ->
            _ =
              publish_command_response(
                state.bus,
                @list_rejected,
                list_rejected_payload(signal.data, reason),
                signal
              )

            {:noreply, state}
        end

      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @list_rejected,
            list_rejected_payload(signal.data, reason),
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_runtime_status_requested(signal, state) do
    status = status_payload(state)

    _ =
      publish_command_response(
        state.bus,
        @runtime_status_accepted,
        %{"status" => to_signal_value(status)},
        signal
      )

    {:noreply, state}
  end

  defp handle_definition_list_requested(signal, state) do
    with {:ok, opts} <- normalize_definition_list_opts(signal.data),
         {:ok, definitions} <- list_workflow_definitions(state.workflow_registry, opts) do
      _ =
        publish_command_response(
          state.bus,
          @definition_list_accepted,
          %{"definitions" => definitions, "count" => length(definitions)},
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @definition_list_rejected,
            definition_list_rejected_payload(signal.data, reason),
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_definition_get_requested(signal, state) do
    with {:ok, workflow_id} <- normalize_required_workflow_id(signal.data),
         {:ok, definition} <- get_workflow_definition(state.workflow_registry, workflow_id) do
      _ =
        publish_command_response(
          state.bus,
          @definition_get_accepted,
          %{"workflow_id" => workflow_id, "definition" => definition},
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @definition_get_rejected,
            %{
              "workflow_id" => fetch_requested_workflow_id(signal.data),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_registry_refresh_requested(signal, state) do
    case refresh_workflow_registry(state.workflow_registry) do
      {:ok, summary} ->
        _ =
          publish_command_response(
            state.bus,
            @registry_refresh_accepted,
            %{"summary" => to_signal_value(summary)},
            signal
          )

        {:noreply, state}

      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @registry_refresh_rejected,
            %{"reason" => format_reason(reason)},
            signal
          )

        {:noreply, state}
    end
  end

  defp handle_registry_reload_requested(signal, state) do
    with {:ok, workflow_id} <- normalize_required_workflow_id(signal.data),
         {:ok, summary} <- reload_workflow_registry(state.workflow_registry, workflow_id) do
      _ =
        publish_command_response(
          state.bus,
          @registry_reload_accepted,
          %{"workflow_id" => workflow_id, "summary" => to_signal_value(summary)},
          signal
        )

      {:noreply, state}
    else
      {:error, reason} ->
        _ =
          publish_command_response(
            state.bus,
            @registry_reload_rejected,
            %{
              "workflow_id" => fetch_requested_workflow_id(signal.data),
              "reason" => format_reason(reason)
            },
            signal
          )

        {:noreply, state}
    end
  end

  defp launch_run_task(request, state) do
    run_id = request.run_id || generate_run_id()
    backend = resolve_backend(request.backend || state.backend)

    with :ok <- ensure_run_not_registered(state, run_id),
         :ok <- ensure_run_id_available(state.run_store, run_id, not is_nil(request.run_id)),
         {:ok, pid} <- start_run_task_process(request, run_id, backend, state) do
      monitor_ref = Process.monitor(pid)

      run_task = %{
        pid: pid,
        monitor_ref: monitor_ref,
        workflow_id: request.workflow_id,
        backend: backend,
        runtime_agent_pid: nil
      }

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

  defp ensure_run_id_available(run_store, run_id, run_id_provided?)
       when is_binary(run_id) and is_boolean(run_id_provided?) do
    case RunStore.get(run_id, run_store) do
      {:ok, _run} -> {:error, {:run_id_already_exists, run_id}}
      {:error, :not_found} -> :ok
    end
  catch
    :exit, reason ->
      if run_id_provided? do
        {:error, {:run_store_unavailable, reason}}
      else
        Logger.warning(
          "Run store unavailable while checking generated run_id #{run_id}; proceeding " <>
            "without persisted uniqueness check: #{inspect(reason)}"
        )

        :ok
      end
  end

  defp start_run_task_process(request, run_id, backend, state) do
    opts =
      [
        registry: state.workflow_registry,
        run_store: state.run_store,
        bus: state.bus,
        run_id: run_id
      ]
      |> maybe_put_backend(backend)
      |> maybe_put_runtime_started_hook(backend, run_id, self())

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

      {%{pid: pid, monitor_ref: monitor_ref, runtime_agent_pid: runtime_agent_pid},
       remaining_tasks} ->
        _ = stop_runtime_agent(runtime_agent_pid)

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

  defp stop_all_run_tasks(state) do
    Enum.reduce(Map.keys(state.run_tasks), state, fn run_id, acc ->
      stop_run_task(acc, run_id)
    end)
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

  defp register_runtime_agent(state, run_id, runtime_agent_pid) when is_pid(runtime_agent_pid) do
    case Map.fetch(state.run_tasks, run_id) do
      {:ok, run_task} ->
        updated_task = Map.put(run_task, :runtime_agent_pid, runtime_agent_pid)
        %{state | run_tasks: Map.put(state.run_tasks, run_id, updated_task)}

      :error ->
        state
    end
  end

  defp register_runtime_agent(state, _run_id, _runtime_agent_pid), do: state

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
    workflow_id = fetch_requested_workflow_id(data)
    run_id = normalize_optional_binary(fetch(data, "run_id"))
    inputs = normalize_start_inputs(data)

    with {:ok, backend} <- normalize_requested_backend(fetch(data, "backend")) do
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
  end

  defp normalize_manual_trigger_request(data) when is_map(data) do
    trigger_id = normalize_optional_binary(fetch(data, "trigger_id"))
    command = normalize_optional_binary(fetch(data, "command"))
    workflow_id = fetch_requested_workflow_id(data)
    params = normalize_manual_trigger_params(data)

    cond do
      params == :invalid ->
        {:error, {:missing_or_invalid, :params}}

      not is_map(params) ->
        {:error, {:missing_or_invalid, :params}}

      valid_binary?(trigger_id) ->
        {:ok,
         %{trigger_id: trigger_id, command: command, workflow_id: workflow_id, params: params}}

      valid_binary?(command) ->
        {:ok, %{trigger_id: nil, command: command, workflow_id: workflow_id, params: params}}

      true ->
        {:error, {:missing_or_invalid, :trigger_reference}}
    end
  end

  defp normalize_manual_trigger_request(_data), do: {:error, {:missing_or_invalid, :request}}

  defp normalize_manual_trigger_params(data) when is_map(data) do
    case fetch(data, "params") do
      nil ->
        data
        |> Map.drop(["trigger_id", "command", "workflow_id", "id"])
        |> Map.drop([:trigger_id, :command, :workflow_id, :id])

      params when is_map(params) ->
        params

      _other ->
        :invalid
    end
  end

  defp normalize_start_inputs(data) when is_map(data) do
    case fetch(data, "inputs") do
      nil ->
        data
        |> Map.drop(["workflow_id", "id", "run_id", "backend"])
        |> Map.drop([:workflow_id, :id, :run_id, :backend])

      inputs when is_map(inputs) ->
        inputs

      _other ->
        :invalid
    end
  end

  defp normalize_start_inputs(_data), do: :invalid

  defp normalize_list_opts(data) when is_map(data) do
    with {:ok, workflow_id} <- optional_requested_workflow_id_filter(data),
         {:ok, status} <- optional_status_filter(data, "status"),
         {:ok, limit} <- optional_positive_integer_filter(data, "limit") do
      opts =
        []
        |> maybe_put_opt(:workflow_id, workflow_id)
        |> maybe_put_opt(:status, status)
        |> maybe_put_opt(:limit, limit)

      {:ok, opts}
    end
  end

  defp normalize_list_opts(_data), do: {:ok, []}

  defp list_rejected_payload(data, reason) do
    %{"reason" => format_reason(reason)}
    |> maybe_put("workflow_id", fetch_list_requested_workflow_id(data))
    |> maybe_put("status", fetch_requested_status_filter(data))
    |> maybe_put("limit", fetch_normalized_limit_filter(data))
  end

  defp optional_requested_workflow_id_filter(data) when is_map(data) do
    value =
      case fetch_with_presence(data, "workflow_id") do
        {:present, workflow_id} -> workflow_id
        :missing -> fetch(data, "id")
      end

    normalize_optional_requested_workflow_id_filter(value)
  end

  defp fetch_list_requested_workflow_id(data) when is_map(data) do
    case optional_requested_workflow_id_filter(data) do
      {:ok, workflow_id} -> workflow_id
      {:error, _reason} -> nil
    end
  end

  defp fetch_list_requested_workflow_id(_data), do: nil

  defp normalize_optional_requested_workflow_id_filter(nil), do: {:ok, nil}

  defp normalize_optional_requested_workflow_id_filter(value) do
    case normalize_optional_binary(value) do
      workflow_id when is_binary(workflow_id) ->
        {:ok, workflow_id}

      _other ->
        {:error, {:missing_or_invalid, :workflow_id}}
    end
  end

  defp normalize_definition_list_opts(data) when is_map(data) do
    with {:ok, include_disabled} <- optional_boolean_filter(data, "include_disabled"),
         {:ok, include_invalid} <- optional_boolean_filter(data, "include_invalid"),
         {:ok, limit} <- optional_positive_integer_filter(data, "limit") do
      {:ok,
       %{
         include_disabled: default_true(include_disabled),
         include_invalid: default_true(include_invalid),
         limit: limit
       }}
    end
  end

  defp normalize_definition_list_opts(_data) do
    {:ok, %{include_disabled: true, include_invalid: true, limit: nil}}
  end

  defp definition_list_rejected_payload(data, reason) do
    %{"reason" => format_reason(reason)}
    |> maybe_put("include_disabled", fetch_normalized_boolean_filter(data, "include_disabled"))
    |> maybe_put("include_invalid", fetch_normalized_boolean_filter(data, "include_invalid"))
    |> maybe_put("limit", fetch_normalized_limit_filter(data))
  end

  defp normalize_required_workflow_id(data) when is_map(data) do
    workflow_id = fetch_requested_workflow_id(data)

    if valid_binary?(workflow_id) do
      {:ok, workflow_id}
    else
      {:error, {:missing_or_invalid, :workflow_id}}
    end
  end

  defp normalize_required_workflow_id(_data), do: {:error, {:missing_or_invalid, :workflow_id}}

  defp default_workflow_id(nil, fallback), do: normalize_optional_binary(fallback)
  defp default_workflow_id(workflow_id, _fallback), do: workflow_id

  defp optional_status_filter(data, key) do
    case fetch(data, key) do
      nil ->
        {:ok, nil}

      status when status in [:running, :paused, :completed, :failed, :cancelled] ->
        {:ok, status}

      status when is_binary(status) ->
        parse_status_filter(status, key)

      _ ->
        {:error, {:missing_or_invalid, String.to_atom(key)}}
    end
  end

  defp parse_status_filter(status, key) when is_binary(status) do
    case normalize_optional_binary(status) do
      nil ->
        {:error, {:missing_or_invalid, String.to_atom(key)}}

      normalized ->
        case String.downcase(normalized) do
          "running" -> {:ok, :running}
          "paused" -> {:ok, :paused}
          "completed" -> {:ok, :completed}
          "failed" -> {:ok, :failed}
          "cancelled" -> {:ok, :cancelled}
          _ -> {:error, {:missing_or_invalid, String.to_atom(key)}}
        end
    end
  end

  defp optional_boolean_filter(data, key) do
    case fetch(data, key) do
      nil ->
        {:ok, nil}

      value when is_boolean(value) ->
        {:ok, value}

      value when is_binary(value) ->
        parse_boolean_filter(value, key)

      _ ->
        {:error, {:missing_or_invalid, String.to_atom(key)}}
    end
  end

  defp parse_boolean_filter(value, key) when is_binary(value) do
    case normalize_optional_binary(value) do
      nil ->
        {:error, {:missing_or_invalid, String.to_atom(key)}}

      normalized ->
        case String.downcase(normalized) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          "1" -> {:ok, true}
          "0" -> {:ok, false}
          _ -> {:error, {:missing_or_invalid, String.to_atom(key)}}
        end
    end
  end

  defp default_true(nil), do: true
  defp default_true(value) when is_boolean(value), do: value

  defp optional_positive_integer_filter(data, key) do
    case fetch(data, key) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        normalized = String.trim(value)

        case Integer.parse(normalized) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, {:missing_or_invalid, String.to_atom(key)}}
        end

      _ ->
        {:error, {:missing_or_invalid, String.to_atom(key)}}
    end
  end

  defp fetch_normalized_limit_filter(data) do
    case fetch(data, "limit") do
      limit when is_integer(limit) ->
        limit

      limit when is_binary(limit) ->
        normalize_optional_binary(limit)

      _other ->
        nil
    end
  end

  defp fetch_normalized_boolean_filter(data, key) do
    case fetch(data, key) do
      value when is_boolean(value) ->
        value

      value when is_atom(value) and not is_nil(value) ->
        Atom.to_string(value)

      value when is_binary(value) ->
        normalize_optional_binary(value)

      _other ->
        nil
    end
  end

  defp fetch_requested_status_filter(data) do
    case fetch(data, "status") do
      status when is_atom(status) ->
        Atom.to_string(status)

      status when is_binary(status) ->
        normalize_optional_binary(status)

      _other ->
        nil
    end
  end

  defp fetch_required_run_id(data) do
    case fetch(data, "run_id") |> normalize_optional_binary() do
      run_id when is_binary(run_id) -> {:ok, run_id}
      _ -> {:error, {:missing_or_invalid, :run_id}}
    end
  end

  defp fetch_cancel_reason(data) do
    case fetch(data, "reason") do
      reason when is_binary(reason) ->
        normalize_optional_binary(reason) || :cancelled

      reason when is_atom(reason) ->
        reason

      _ ->
        :cancelled
    end
  end

  defp fetch_requested_cancel_reason(data) do
    case fetch(data, "reason") do
      reason when is_binary(reason) ->
        normalize_optional_binary(reason)

      reason when is_atom(reason) ->
        Atom.to_string(reason)

      _other ->
        nil
    end
  end

  defp fetch_required_mode(data) do
    case fetch(data, "mode") do
      mode when mode in [:auto, :step] ->
        {:ok, mode}

      mode when is_binary(mode) ->
        parse_mode(mode)

      _ ->
        {:error, {:missing_or_invalid, :mode}}
    end
  end

  defp fetch_requested_mode(data) do
    case fetch(data, "mode") do
      mode when is_atom(mode) and not is_nil(mode) ->
        Atom.to_string(mode)

      mode when is_binary(mode) ->
        normalize_optional_binary(mode)

      _other ->
        nil
    end
  end

  defp parse_mode(mode) when is_binary(mode) do
    case normalize_optional_binary(mode) do
      nil -> {:error, {:missing_or_invalid, :mode}}
      normalized -> normalize_mode_value(String.downcase(normalized))
    end
  end

  defp normalize_mode_value("auto"), do: {:ok, :auto}
  defp normalize_mode_value("step"), do: {:ok, :step}
  defp normalize_mode_value(_mode), do: {:error, {:missing_or_invalid, :mode}}

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
    [
      @start_requested,
      @pause_requested,
      @step_requested,
      @mode_requested,
      @resume_requested,
      @cancel_requested,
      @get_requested,
      @list_requested,
      @runtime_status_requested,
      @definition_list_requested,
      @definition_get_requested,
      @registry_refresh_requested,
      @registry_reload_requested,
      @manual_trigger_requested,
      @trigger_refresh_requested,
      @trigger_sync_requested,
      @trigger_runtime_status_requested
    ]
  end

  defp status_payload(state) do
    %{
      bus: state.bus,
      backend: state.backend,
      workflow_registry: state.workflow_registry,
      trigger_supervisor: state.trigger_supervisor,
      trigger_process_registry: state.trigger_process_registry,
      trigger_runtime: state.trigger_runtime,
      subscription_count: length(state.subscription_ids),
      run_tasks:
        Enum.into(state.run_tasks, %{}, fn {run_id, run_task} ->
          {run_id,
           %{
             workflow_id: run_task.workflow_id,
             backend: run_task.backend,
             runtime_agent_pid: run_task.runtime_agent_pid,
             task_alive?: Process.alive?(run_task.pid)
           }}
        end)
    }
  end

  defp maybe_pause_strategy_runtime(state, run_id) do
    with {:ok, run_task} <- fetch_run_task(state, run_id),
         :strategy <- run_task.backend,
         {:ok, runtime_agent_pid} <- fetch_runtime_agent_pid(run_task) do
      send_runtime_signal(
        runtime_agent_pid,
        "runic.set_mode",
        %{mode: :step},
        runtime_source(run_id, "pause")
      )
    else
      :direct -> :ok
      nil -> :ok
      {:error, :run_not_tracked} -> :ok
      {:error, :runtime_agent_unavailable} -> {:error, :runtime_agent_unavailable}
    end
  end

  defp ensure_active_run_status(run) do
    case run.status do
      status when status in [:running, :paused] ->
        :ok

      status ->
        {:error, {:invalid_transition, status, :active_control}}
    end
  end

  defp apply_run_mode_transition(:step, %{status: :running} = run, state) do
    case pause_run(run.run_id, state) do
      :ok ->
        get_run(run.run_id, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_run_mode_transition(:step, %{status: :paused} = run, _state), do: {:ok, run}

  defp apply_run_mode_transition(:auto, %{status: :paused} = run, state) do
    case resume_run(run.run_id, state) do
      :ok ->
        get_run(run.run_id, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_run_mode_transition(:auto, %{status: :running} = run, _state), do: {:ok, run}

  defp apply_run_mode_transition(mode, run, _state),
    do: {:error, {:invalid_transition, run.status, mode}}

  defp fetch_strategy_runtime_agent(state, run_id, run) do
    case run.backend do
      :strategy ->
        case fetch_run_task(state, run_id) do
          {:ok, run_task} ->
            fetch_runtime_agent_pid(run_task)

          {:error, :run_not_tracked} ->
            {:error, :runtime_agent_unavailable}
        end

      backend ->
        {:error, {:unsupported_backend, backend}}
    end
  end

  defp maybe_resume_strategy_runtime(state, run_id) do
    with {:ok, run_task} <- fetch_run_task(state, run_id),
         :strategy <- run_task.backend,
         {:ok, runtime_agent_pid} <- fetch_runtime_agent_pid(run_task) do
      send_runtime_signal(
        runtime_agent_pid,
        "runic.resume",
        %{},
        runtime_source(run_id, "resume")
      )
    else
      :direct -> :ok
      nil -> :ok
      {:error, :run_not_tracked} -> :ok
      {:error, :runtime_agent_unavailable} -> {:error, :runtime_agent_unavailable}
    end
  end

  defp maybe_stop_strategy_runtime(state, run_id) do
    with {:ok, run_task} <- fetch_run_task(state, run_id),
         :strategy <- run_task.backend,
         {:ok, runtime_agent_pid} <- fetch_runtime_agent_pid(run_task) do
      stop_runtime_agent(runtime_agent_pid)
    else
      :direct -> :ok
      nil -> :ok
      {:error, :run_not_tracked} -> :ok
      {:error, :runtime_agent_unavailable} -> :ok
    end
  end

  defp fetch_run_task(state, run_id) do
    case Map.fetch(state.run_tasks, run_id) do
      {:ok, run_task} -> {:ok, run_task}
      :error -> {:error, :run_not_tracked}
    end
  end

  defp pause_run(run_id, state) do
    Engine.pause(run_id, run_store: state.run_store, bus: state.bus)
  catch
    :exit, reason -> {:error, {:run_store_unavailable, reason}}
  end

  defp resume_run(run_id, state) do
    Engine.resume(run_id, run_store: state.run_store, bus: state.bus)
  catch
    :exit, reason -> {:error, {:run_store_unavailable, reason}}
  end

  defp cancel_run(run_id, reason, state) do
    Engine.cancel(run_id, run_store: state.run_store, bus: state.bus, reason: reason)
  catch
    :exit, exit_reason -> {:error, {:run_store_unavailable, exit_reason}}
  end

  defp get_run(run_id, state) do
    Engine.get_run(run_id, run_store: state.run_store)
  catch
    :exit, reason -> {:error, {:run_store_unavailable, reason}}
  end

  defp list_runs(list_opts, state) do
    runs =
      list_opts
      |> Keyword.put(:run_store, state.run_store)
      |> Engine.list_runs()

    {:ok, runs}
  catch
    :exit, reason -> {:error, {:run_store_unavailable, reason}}
  end

  defp fetch_runtime_agent_pid(%{runtime_agent_pid: runtime_agent_pid})
       when is_pid(runtime_agent_pid),
       do: {:ok, runtime_agent_pid}

  defp fetch_runtime_agent_pid(_run_task), do: {:error, :runtime_agent_unavailable}

  defp send_runtime_signal(runtime_agent_pid, signal_type, data, source) do
    signal = Signal.new!(signal_type, data, source: source)

    case Jido.AgentServer.call(runtime_agent_pid, signal) do
      {:ok, _agent} ->
        :ok

      {:error, reason} ->
        {:error, {:runtime_command_failed, signal_type, reason}}
    end
  catch
    :exit, reason ->
      {:error, {:runtime_agent_exit, reason}}
  end

  defp stop_runtime_agent(runtime_agent_pid) when is_pid(runtime_agent_pid) do
    if Process.alive?(runtime_agent_pid) do
      GenServer.stop(runtime_agent_pid, :normal, 1_000)
    else
      :ok
    end
  catch
    :exit, _reason ->
      :ok
  end

  defp stop_runtime_agent(_runtime_agent_pid), do: :ok

  defp maybe_put_runtime_started_hook(opts, :strategy, run_id, parent) do
    callback = fn runtime_agent_pid ->
      send(parent, {:command_run_runtime_agent_started, run_id, runtime_agent_pid})
    end

    Keyword.put(opts, :on_runtime_agent_started, callback)
  end

  defp maybe_put_runtime_started_hook(opts, _backend, _run_id, _parent), do: opts

  defp runtime_source(run_id, suffix) do
    @command_source <> "/" <> run_id <> "/" <> suffix
  end

  defp execute_manual_trigger_request(request, state) do
    opts = trigger_opts(state)

    case request do
      %{trigger_id: trigger_id} when is_binary(trigger_id) and trigger_id != "" ->
        with {:ok, execution} <-
               TriggerSupervisor.trigger_manual(trigger_id, request.params, opts) do
          {:ok, trigger_id, execution}
        end

      %{command: command} when is_binary(command) and command != "" ->
        lookup_opts =
          [process_registry: state.trigger_process_registry]
          |> maybe_put_opt(:workflow_id, request.workflow_id)

        with {:ok, trigger_id} <- TriggerSupervisor.lookup_manual_by_command(command, lookup_opts),
             {:ok, execution} <-
               TriggerSupervisor.trigger_manual(trigger_id, request.params, opts) do
          {:ok, trigger_id, execution}
        end
    end
  end

  defp list_workflow_definitions(workflow_registry, opts) do
    items =
      WorkflowRegistry.list(
        workflow_registry,
        include_disabled: opts.include_disabled,
        include_invalid: opts.include_invalid
      )
      |> maybe_limit_items(opts.limit)

    {:ok, Enum.map(items, &to_signal_value/1)}
  catch
    :exit, reason ->
      {:error, {:workflow_registry_unavailable, reason}}
  end

  defp get_workflow_definition(workflow_registry, workflow_id) do
    case WorkflowRegistry.get_definition(workflow_id, workflow_registry) do
      {:ok, definition} -> {:ok, to_signal_value(definition)}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason ->
      {:error, {:workflow_registry_unavailable, reason}}
  end

  defp refresh_workflow_registry(workflow_registry) do
    WorkflowRegistry.refresh(workflow_registry)
  catch
    :exit, reason ->
      {:error, {:workflow_registry_unavailable, reason}}
  end

  defp reload_workflow_registry(workflow_registry, workflow_id) do
    WorkflowRegistry.reload(workflow_id, workflow_registry)
  catch
    :exit, reason ->
      {:error, {:workflow_registry_unavailable, reason}}
  end

  defp maybe_limit_items(items, nil), do: items

  defp maybe_limit_items(items, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(items, limit)

  defp refresh_trigger_runtime(trigger_runtime) do
    TriggerRuntime.refresh(trigger_runtime)
  catch
    :exit, reason ->
      {:error, {:trigger_runtime_unavailable, reason}}
  end

  defp sync_trigger_runtime(trigger_runtime) do
    TriggerRuntime.sync(trigger_runtime)
  catch
    :exit, reason ->
      {:error, {:trigger_runtime_unavailable, reason}}
  end

  defp trigger_runtime_status(trigger_runtime) do
    {:ok, TriggerRuntime.status(trigger_runtime)}
  catch
    :exit, reason ->
      {:error, {:trigger_runtime_unavailable, reason}}
  end

  defp trigger_opts(state) do
    [
      supervisor: state.trigger_supervisor,
      process_registry: state.trigger_process_registry
    ]
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_backend(opts, nil), do: opts
  defp maybe_put_backend(opts, backend), do: Keyword.put(opts, :backend, backend)

  defp resolve_backend(value) when value in [:direct, :strategy], do: value
  defp resolve_backend(_value), do: default_engine_backend()

  defp normalize_backend(value) when value in [:direct, :strategy], do: value

  defp normalize_backend(value) when is_binary(value) do
    case normalize_optional_binary(value) do
      nil ->
        nil

      normalized ->
        case String.downcase(normalized) do
          "direct" -> :direct
          "strategy" -> :strategy
          _ -> nil
        end
    end
  end

  defp normalize_backend(_value), do: nil

  defp normalize_requested_backend(nil), do: {:ok, nil}

  defp normalize_requested_backend(value) do
    case normalize_backend(value) do
      nil -> {:error, {:missing_or_invalid, :backend}}
      backend -> {:ok, backend}
    end
  end

  defp normalize_optional_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_binary(_value), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp serialize_run(run) do
    %{
      "run_id" => run.run_id,
      "workflow_id" => run.workflow_id,
      "status" => to_string(run.status),
      "backend" => format_backend(run.backend),
      "inputs" => to_signal_value(run.inputs),
      "started_at" => format_datetime(run.started_at),
      "finished_at" => format_datetime(run.finished_at),
      "result" => to_signal_value(run.result),
      "error" => to_signal_value(run.error)
    }
  end

  defp format_backend(nil), do: nil
  defp format_backend(backend) when is_atom(backend), do: Atom.to_string(backend)
  defp format_backend(backend), do: to_signal_value(backend)

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(datetime), do: to_signal_value(datetime)

  defp to_signal_value(nil), do: nil
  defp to_signal_value(value) when is_binary(value), do: value
  defp to_signal_value(value) when is_boolean(value), do: value
  defp to_signal_value(value) when is_integer(value), do: value
  defp to_signal_value(value) when is_float(value), do: value
  defp to_signal_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_signal_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_signal_value(%_{} = value), do: value |> Map.from_struct() |> to_signal_value()

  defp to_signal_value(value) when is_map(value) do
    value
    |> Enum.into(%{}, fn {key, item} ->
      {to_string(key), to_signal_value(item)}
    end)
  end

  defp to_signal_value(value) when is_list(value), do: Enum.map(value, &to_signal_value/1)
  defp to_signal_value(value), do: inspect(value)

  defp valid_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp fetch(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        fetch_atom_key(map, key)
    end
  end

  defp fetch(_map, _key), do: nil

  defp fetch_with_presence(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:present, value}

      :error ->
        fetch_atom_key_with_presence(map, key)
    end
  end

  defp fetch_with_presence(_map, _key), do: :missing

  defp fetch_normalized_binary(map, key) when is_binary(key) do
    map
    |> fetch(key)
    |> normalize_optional_binary()
  end

  defp fetch_requested_workflow_id(data) when is_map(data) do
    fetch(data, "workflow_id")
    |> normalize_optional_binary()
    |> default_workflow_id(fetch(data, "id"))
  end

  defp fetch_requested_workflow_id(_data), do: nil

  defp fetch_atom_key(map, key) do
    Enum.find_value(map, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

  defp fetch_atom_key_with_presence(map, key) do
    case Enum.find(map, fn
           {map_key, _map_value} when is_atom(map_key) ->
             Atom.to_string(map_key) == key

           _other ->
             false
         end) do
      {_map_key, map_value} ->
        {:present, map_value}

      nil ->
        :missing
    end
  end

  defp default_workflow_registry do
    Application.get_env(:jido_workflow, :workflow_registry, WorkflowRegistry)
  end

  defp default_trigger_supervisor do
    Application.get_env(:jido_workflow, :trigger_supervisor, TriggerSupervisor)
  end

  defp default_trigger_process_registry do
    Application.get_env(
      :jido_workflow,
      :trigger_process_registry,
      JidoWorkflow.Workflow.TriggerProcessRegistry
    )
  end

  defp default_trigger_runtime do
    Application.get_env(:jido_workflow, :trigger_runtime, TriggerRuntime)
  end

  defp default_run_store do
    Application.get_env(:jido_workflow, :run_store, RunStore)
  end

  defp default_engine_backend do
    Application.get_env(:jido_workflow, :engine_backend, :direct)
  end

  defp generate_run_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
