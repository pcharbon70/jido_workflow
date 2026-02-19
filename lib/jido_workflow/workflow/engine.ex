defmodule JidoWorkflow.Workflow.Engine do
  @moduledoc """
  Executes compiled workflows and emits lifecycle signals.

  Supports two execution backends:
  - `:direct` (default): execute Runic workflow directly in-process
  - `:strategy`: execute through `Jido.Runic.Strategy` using an AgentServer
  """

  alias Jido.Agent.Strategy.State, as: StratState
  alias Jido.Signal
  alias JidoWorkflow.Workflow.ArgumentResolver
  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Compiler
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Registry
  alias JidoWorkflow.Workflow.ReturnProjector
  alias JidoWorkflow.Workflow.RuntimeAgent
  alias Runic.Workflow

  @type backend :: :direct | :strategy

  @type execution_result :: %{
          run_id: String.t(),
          workflow_id: String.t(),
          status: :completed,
          result: term(),
          productions: [term()],
          workflow: Workflow.t()
        }

  @spec execute(String.t(), map(), keyword()) :: {:ok, execution_result()} | {:error, term()}
  def execute(workflow_id, inputs, opts \\ []) when is_binary(workflow_id) and is_map(inputs) do
    registry = Keyword.get(opts, :registry, Registry)

    with {:ok, compiled} <- Registry.get_compiled(workflow_id, registry) do
      execute_compiled(compiled, inputs, Keyword.put_new(opts, :workflow_id, workflow_id))
    end
  end

  @spec execute_definition(Definition.t(), map(), keyword()) ::
          {:ok, execution_result()} | {:error, term()}
  def execute_definition(%Definition{} = definition, inputs, opts \\ []) when is_map(inputs) do
    with {:ok, compiled} <- Compiler.compile(definition) do
      execute_compiled(compiled, inputs, opts)
    end
  end

  @spec execute_compiled(map(), map(), keyword()) :: {:ok, execution_result()} | {:error, term()}
  def execute_compiled(compiled, inputs, opts \\ []) when is_map(compiled) and is_map(inputs) do
    with {:ok, backend} <- resolve_backend(opts) do
      workflow_id = workflow_id(compiled, opts)
      run_id = Keyword.get_lazy(opts, :run_id, &generate_run_id/0)
      settings = compiled_settings(compiled)

      state = %{
        "inputs" => normalize_inputs(inputs),
        "results" => %{}
      }

      metadata =
        %{
          "inputs" => state["inputs"],
          "backend" => Atom.to_string(backend)
        }
        |> maybe_put_setting_metadata(settings)

      _ = maybe_broadcast_started(workflow_id, run_id, metadata, opts)

      case run_backend(backend, compiled.workflow, state, workflow_id, opts, settings) do
        {:ok, executed, productions} ->
          handle_projected_result(
            compiled,
            workflow_id,
            run_id,
            executed,
            productions,
            opts
          )

        {:error, reason} ->
          _ = maybe_broadcast_failed(workflow_id, run_id, reason, opts)
          {:error, {:execution_failed, reason}}
      end
    end
  end

  defp run_backend(:direct, workflow, state, _workflow_id, opts, settings) do
    runic_opts = runic_opts(opts, settings)

    try do
      executed = Workflow.react_until_satisfied(workflow, state, runic_opts)
      {:ok, executed, Workflow.raw_productions(executed)}
    rescue
      exception ->
        {:error, {:exception, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:caught, kind, reason}}
    end
  end

  defp run_backend(:strategy, workflow, state, workflow_id, opts, settings) do
    with_runtime_agent(opts, fn pid ->
      with :ok <- set_runtime_workflow(pid, workflow, workflow_id),
           :ok <- feed_runtime_inputs(pid, state, workflow_id),
           {:ok, completion} <- await_runtime_completion(pid, opts, settings),
           :ok <- ensure_runtime_completed(completion),
           {:ok, executed} <- fetch_runtime_workflow(pid) do
        {:ok, executed, Workflow.raw_productions(executed)}
      end
    end)
  end

  defp handle_projected_result(compiled, workflow_id, run_id, executed, productions, opts) do
    case ReturnProjector.project(productions, compiled[:return]) do
      {:ok, result} ->
        _ = maybe_broadcast_completed(workflow_id, run_id, result, opts)

        {:ok,
         %{
           run_id: run_id,
           workflow_id: workflow_id,
           status: :completed,
           result: result,
           productions: productions,
           workflow: executed
         }}

      {:error, reason} ->
        _ = maybe_broadcast_failed(workflow_id, run_id, reason, opts)
        {:error, {:return_projection_failed, reason}}
    end
  end

  defp with_runtime_agent(opts, fun) when is_function(fun, 1) do
    debug = Keyword.get(opts, :debug_runtime, false)

    with :ok <- ensure_runtime_dependencies() do
      case Jido.AgentServer.start_link(
             agent: RuntimeAgent,
             jido: Jido,
             debug: debug,
             register_global: false,
             skip_schedules: true
           ) do
        {:ok, pid} ->
          Process.unlink(pid)

          try do
            fun.(pid)
          after
            stop_runtime_agent(pid)
          end

        {:error, reason} ->
          {:error, {:agent_start_failed, reason}}
      end
    end
  end

  defp set_runtime_workflow(pid, workflow, workflow_id) do
    signal =
      Signal.new!(
        "runic.set_workflow",
        %{workflow: workflow},
        source: runtime_source(workflow_id, "set_workflow")
      )

    case Jido.AgentServer.call(pid, signal) do
      {:ok, _agent} -> :ok
      {:error, reason} -> {:error, {:set_workflow_failed, reason}}
    end
  end

  defp feed_runtime_inputs(pid, state, workflow_id) do
    signal =
      Signal.new!(
        "runic.feed",
        %{data: state},
        source: runtime_source(workflow_id, "feed")
      )

    case Jido.AgentServer.cast(pid, signal) do
      :ok -> :ok
      {:error, reason} -> {:error, {:feed_failed, reason}}
    end
  end

  defp await_runtime_completion(pid, opts, settings) do
    timeout = resolve_await_timeout(opts, settings)

    case Jido.AgentServer.await_completion(pid, timeout: timeout) do
      {:ok, completion} -> {:ok, completion}
      {:error, reason} -> {:error, {:await_completion_failed, reason}}
    end
  end

  defp ensure_runtime_completed(%{status: :completed}), do: :ok

  defp ensure_runtime_completed(%{status: :failed} = completion) do
    {:error, {:runic_failed, Map.get(completion, :result)}}
  end

  defp ensure_runtime_completed(other), do: {:error, {:unexpected_completion_status, other}}

  defp fetch_runtime_workflow(pid) do
    with {:ok, server_state} <- Jido.AgentServer.state(pid) do
      strat = StratState.get(server_state.agent, %{})

      case Map.get(strat, :workflow) do
        %Workflow{} = workflow -> {:ok, workflow}
        other -> {:error, {:missing_strategy_workflow, other}}
      end
    end
  end

  defp stop_runtime_agent(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 1_000)
    else
      :ok
    end
  catch
    :exit, _reason ->
      :ok
  end

  defp ensure_runtime_dependencies do
    with {:ok, _apps} <- Application.ensure_all_started(:jido),
         {:ok, _apps} <- Application.ensure_all_started(:jido_runic),
         {:ok, _pid} <- Jido.start(name: Jido) do
      :ok
    else
      {:error, reason} ->
        {:error, {:runtime_dependencies_failed, reason}}
    end
  end

  defp resolve_backend(opts) do
    backend = Keyword.get(opts, :backend, default_backend())

    if backend in [:direct, :strategy] do
      {:ok, backend}
    else
      {:error, {:invalid_backend, backend}}
    end
  end

  defp default_backend do
    Application.get_env(:jido_workflow, :engine_backend, :direct)
  end

  defp workflow_id(compiled, opts) do
    Keyword.get_lazy(opts, :workflow_id, fn ->
      compiled
      |> get_in([:metadata, :name])
      |> case do
        name when is_binary(name) and name != "" -> name
        _ -> "workflow"
      end
    end)
  end

  defp normalize_inputs(inputs) do
    inputs
    |> ArgumentResolver.normalize_state()
    |> Map.get("inputs", %{})
  end

  defp runic_opts(opts, settings) do
    async? = Keyword.get(opts, :async, false)
    timeout = Keyword.get(opts, :timeout, workflow_timeout(settings) || :infinity)

    max_concurrency =
      case Keyword.get(opts, :max_concurrency, workflow_max_concurrency(settings)) do
        value when is_integer(value) and value > 0 -> value
        _ -> nil
      end

    [
      async: async?,
      timeout: timeout,
      max_concurrency: max_concurrency
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_broadcast_started(workflow_id, run_id, metadata, opts) do
    Broadcaster.broadcast_workflow_started(workflow_id, run_id, metadata, broadcast_opts(opts))
  end

  defp maybe_broadcast_completed(workflow_id, run_id, result, opts) do
    Broadcaster.broadcast_workflow_completed(workflow_id, run_id, result, broadcast_opts(opts))
  end

  defp maybe_broadcast_failed(workflow_id, run_id, reason, opts) do
    Broadcaster.broadcast_workflow_failed(workflow_id, run_id, reason, broadcast_opts(opts))
  end

  defp broadcast_opts(opts) do
    [bus: Keyword.get(opts, :bus, Broadcaster.default_bus())]
  end

  defp maybe_put_setting_metadata(metadata, settings) do
    metadata
    |> maybe_put("timeout_ms", workflow_timeout(settings))
    |> maybe_put("max_concurrency", workflow_max_concurrency(settings))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp runtime_source(workflow_id, suffix) do
    "/jido_workflow/workflow/#{workflow_id}/#{suffix}"
  end

  defp compiled_settings(compiled) when is_map(compiled) do
    case Map.get(compiled, :settings) || Map.get(compiled, "settings") do
      %{} = settings -> settings
      _ -> %{}
    end
  end

  defp workflow_timeout(settings) do
    case fetch_setting(settings, :timeout_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp workflow_max_concurrency(settings) do
    case fetch_setting(settings, :max_concurrency) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp resolve_await_timeout(opts, settings) do
    timeout =
      Keyword.get_lazy(opts, :await_timeout, fn ->
        Keyword.get_lazy(opts, :timeout, fn ->
          workflow_timeout(settings) || 300_000
        end)
      end)

    normalize_await_timeout(timeout)
  end

  defp normalize_await_timeout(:infinity), do: :infinity
  defp normalize_await_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_await_timeout(_timeout), do: 300_000

  defp fetch_setting(settings, key) when is_map(settings) do
    Map.get(settings, key) || Map.get(settings, Atom.to_string(key))
  end

  defp generate_run_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
