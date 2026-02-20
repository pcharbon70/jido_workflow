defmodule JidoWorkflow.Workflow.Actions.ExecuteSubWorkflowStep do
  @moduledoc """
  Executes compiled sub-workflow steps.

  Sub-workflow step metadata includes:
  - target workflow id
  - input bindings resolved from workflow state
  - optional condition binding
  """

  alias JidoWorkflow.Workflow.ArgumentResolver
  alias JidoWorkflow.Workflow.Broadcaster
  alias JidoWorkflow.Workflow.Engine
  alias JidoWorkflow.Workflow.Registry

  use Jido.Action,
    name: "workflow_execute_sub_workflow_step",
    description: "Execute a compiled workflow sub-workflow step",
    schema: [
      step: [type: :map, required: true]
    ]

  @workflow_context_key "__workflow"
  @broadcast_event_step_started "step_started"
  @broadcast_event_step_completed "step_completed"
  @broadcast_event_step_failed "step_failed"

  @impl true
  def run(%{step: step} = params, _context) do
    state =
      params
      |> extract_runtime_state()
      |> ArgumentResolver.normalize_state()

    with {:ok, step_meta} <- normalize_step(step) do
      _ = maybe_broadcast_step_started(state, step_meta)

      case execute_sub_workflow_step(step_meta, state, params) do
        {:ok, step_result} ->
          _ = maybe_broadcast_step_completed(state, step_meta, step_result)
          {:ok, ArgumentResolver.put_result(state, step_meta.name, step_result)}

        {:error, reason} = error ->
          _ = maybe_broadcast_step_failed(state, step_meta, reason)
          error
      end
    end
  end

  defp execute_sub_workflow_step(step_meta, state, params) do
    with {:ok, should_run?} <- evaluate_condition(step_meta.condition, state) do
      execute_sub_workflow(step_meta, state, should_run?, params)
    end
  end

  defp extract_runtime_state(params) when is_map(params) do
    case fetch(params, "input") do
      nil ->
        params
        |> Map.delete(:step)
        |> Map.delete("step")

      input ->
        input
    end
  end

  defp normalize_step(step) when is_map(step) do
    name = fetch(step, "name")
    workflow = fetch(step, "workflow")
    inputs = fetch(step, "inputs") || %{}
    condition = fetch(step, "condition")

    cond do
      is_nil(name) ->
        {:error, {:invalid_step, "step name is missing"}}

      is_nil(workflow) ->
        {:error, {:invalid_step, "sub_workflow target is missing"}}

      true ->
        {:ok,
         %{
           name: to_string(name),
           type: normalize_step_type(fetch(step, "type"), "sub_workflow"),
           workflow: to_string(workflow),
           inputs: inputs,
           condition: condition
         }}
    end
  end

  defp normalize_step(other),
    do: {:error, {:invalid_step, "step must be a map, got: #{inspect(other)}"}}

  defp evaluate_condition(nil, _state), do: {:ok, true}

  defp evaluate_condition(condition, state) do
    with {:ok, resolved} <- ArgumentResolver.resolve_inputs(%{"condition" => condition}, state) do
      {:ok, truthy?(resolved["condition"])}
    end
  end

  defp execute_sub_workflow(_step_meta, _state, false, _params) do
    {:ok, %{"status" => "skipped", "reason" => "condition_not_met"}}
  end

  defp execute_sub_workflow(step_meta, state, true, params) do
    with {:ok, resolved_inputs} <- ArgumentResolver.resolve_inputs(step_meta.inputs, state) do
      registry = fetch(params, "registry") || default_registry()
      backend = resolve_backend(fetch(params, "backend"), workflow_context(state))
      bus = context_bus(workflow_context(state))
      run_store = fetch(params, "run_store")

      engine_opts =
        [
          registry: registry,
          backend: backend
        ]
        |> maybe_put_opt(:bus, bus)
        |> maybe_put_opt(:run_store, run_store)

      case Engine.execute(step_meta.workflow, resolved_inputs, engine_opts) do
        {:ok, execution} ->
          {:ok, execution.result}

        {:error, :not_found} ->
          {:error, {:sub_workflow_not_found, step_meta.workflow}}

        {:error, reason} ->
          {:error, {:sub_workflow_failed, step_meta.workflow, reason}}
      end
    end
  end

  defp maybe_broadcast_step_started(state, step_meta) do
    if broadcast_event_enabled?(state, @broadcast_event_step_started) do
      with {:ok, workflow_id, run_id} <- workflow_run_identifiers(state) do
        Broadcaster.broadcast_step_started(
          workflow_id,
          run_id,
          step_payload(step_meta),
          broadcast_opts(state)
        )
      end
    else
      :ok
    end
  end

  defp maybe_broadcast_step_completed(state, step_meta, result) do
    if broadcast_event_enabled?(state, @broadcast_event_step_completed) do
      with {:ok, workflow_id, run_id} <- workflow_run_identifiers(state) do
        Broadcaster.broadcast_step_completed(
          workflow_id,
          run_id,
          step_payload(step_meta),
          result,
          broadcast_opts(state)
        )
      end
    else
      :ok
    end
  end

  defp maybe_broadcast_step_failed(state, step_meta, reason) do
    if broadcast_event_enabled?(state, @broadcast_event_step_failed) do
      with {:ok, workflow_id, run_id} <- workflow_run_identifiers(state) do
        Broadcaster.broadcast_step_failed(
          workflow_id,
          run_id,
          step_payload(step_meta),
          reason,
          broadcast_opts(state)
        )
      end
    else
      :ok
    end
  end

  defp step_payload(step_meta) do
    %{
      "name" => step_meta.name,
      "type" => step_meta.type
    }
  end

  defp workflow_run_identifiers(state) do
    context = workflow_context(state)
    workflow_id = fetch_context_value(context, "workflow_id")
    run_id = fetch_context_value(context, "run_id")

    if is_binary(workflow_id) and workflow_id != "" and is_binary(run_id) and run_id != "" do
      {:ok, workflow_id, run_id}
    else
      :skip
    end
  end

  defp workflow_context(state) do
    state
    |> Map.get("inputs", %{})
    |> fetch_context_value(@workflow_context_key)
    |> case do
      %{} = context -> context
      _ -> %{}
    end
  end

  defp broadcast_event_enabled?(state, event_name) do
    context = workflow_context(state)

    events =
      fetch_context_value(context, "publish_events") ||
        fetch_context_value(context, "broadcast_events")

    case events do
      nil ->
        true

      events when is_list(events) ->
        event_name in events

      _other ->
        true
    end
  end

  defp broadcast_opts(state) do
    context = workflow_context(state)

    []
    |> maybe_put_opt(:bus, context_bus(context))
    |> maybe_put_opt(:source, fetch_context_value(context, "source"))
  end

  defp context_bus(context) do
    case fetch_context_value(context, "bus") do
      bus when is_atom(bus) ->
        bus

      bus when is_binary(bus) ->
        try do
          String.to_existing_atom(bus)
        rescue
          ArgumentError -> Broadcaster.default_bus()
        end

      _ ->
        Broadcaster.default_bus()
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_step_type(nil, default), do: default
  defp normalize_step_type(type, _default) when is_binary(type), do: type
  defp normalize_step_type(type, _default) when is_atom(type), do: Atom.to_string(type)
  defp normalize_step_type(_type, default), do: default

  defp default_registry do
    Application.get_env(:jido_workflow, :workflow_registry, Registry)
  end

  defp resolve_backend(explicit_value, context) do
    explicit_backend = parse_backend(explicit_value)
    context_backend = parse_backend(fetch_context_value(context, "backend"))

    explicit_backend || context_backend || :direct
  end

  defp parse_backend(value) when value in [:direct, :strategy], do: value

  defp parse_backend(value) when is_binary(value) do
    case String.downcase(value) do
      "strategy" -> :strategy
      "direct" -> :direct
      _ -> nil
    end
  end

  defp parse_backend(_value), do: nil

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true

  defp fetch(step, key) when is_map(step) do
    case Map.fetch(step, key) do
      {:ok, value} -> value
      :error -> fetch_atom_key(step, key)
    end
  end

  defp fetch_atom_key(step, key) do
    Enum.find_value(step, fn
      {map_key, map_value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: map_value

      _other ->
        nil
    end)
  end

  defp fetch_context_value(value, _key) when not is_map(value), do: nil

  defp fetch_context_value(value, key) do
    string_key = to_string(key)
    Map.get(value, key) || Map.get(value, string_key) || fetch_atom_key(value, string_key)
  end
end
