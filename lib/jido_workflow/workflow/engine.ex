defmodule JidoWorkflow.Workflow.Engine do
  @moduledoc """
  Executes compiled workflows and emits lifecycle signals.

  Current scope:
  - synchronous execution of a compiled Runic workflow
  - return projection from final productions
  - signal-native lifecycle broadcasting
  """

  alias JidoWorkflow.Workflow.ArgumentResolver
  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Compiler
  alias JidoWorkflow.Workflow.Definition
  alias JidoWorkflow.Workflow.Registry
  alias JidoWorkflow.Workflow.ReturnProjector
  alias Runic.Workflow

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
    workflow_id = workflow_id(compiled, opts)
    run_id = Keyword.get_lazy(opts, :run_id, &generate_run_id/0)

    state = %{
      "inputs" => normalize_inputs(inputs),
      "results" => %{}
    }

    metadata = %{"inputs" => state["inputs"]}
    _ = maybe_broadcast_started(workflow_id, run_id, metadata, opts)

    runic_opts = runic_opts(opts)

    try do
      executed = Workflow.react_until_satisfied(compiled.workflow, state, runic_opts)
      productions = Workflow.raw_productions(executed)

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
    rescue
      exception ->
        reason = {:exception, Exception.message(exception)}
        _ = maybe_broadcast_failed(workflow_id, run_id, reason, opts)
        {:error, {:execution_failed, reason}}
    catch
      kind, reason ->
        wrapped = {:caught, kind, reason}
        _ = maybe_broadcast_failed(workflow_id, run_id, wrapped, opts)
        {:error, {:execution_failed, wrapped}}
    end
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

  defp runic_opts(opts) do
    async? = Keyword.get(opts, :async, false)
    timeout = Keyword.get(opts, :timeout, :infinity)

    max_concurrency =
      case Keyword.get(opts, :max_concurrency) do
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

  defp generate_run_id do
    "run_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
