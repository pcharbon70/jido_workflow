defmodule Jido.Code.Workflow.Actions.ExecuteSkillStep do
  @moduledoc """
  Executes compiled skill workflow steps.

  Skill step metadata includes the target skill module and input bindings.
  Input bindings support `input:` and `result:` references resolved against
  the current workflow state.
  """

  alias Jido.Code.Workflow.ArgumentResolver
  alias Jido.Code.Workflow.Broadcaster

  use Jido.Action,
    name: "workflow_execute_skill_step",
    description: "Execute a compiled workflow skill step",
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

      case execute_skill_step(step_meta, state) do
        {:ok, result} ->
          _ = maybe_broadcast_step_completed(state, step_meta, result)
          {:ok, ArgumentResolver.put_result(state, step_meta.name, result)}

        {:error, reason} = error ->
          _ = maybe_broadcast_step_failed(state, step_meta, reason)
          error
      end
    end
  end

  defp execute_skill_step(step_meta, state) do
    with {:ok, skill_module} <- resolve_module(step_meta.module),
         :ok <- ensure_skill_callback(skill_module),
         {:ok, resolved_inputs} <- ArgumentResolver.resolve_inputs(step_meta.inputs, state) do
      run_skill(skill_module, resolved_inputs, state, step_meta)
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
    module = fetch(step, "module")
    inputs = fetch(step, "inputs")
    timeout_ms = fetch(step, "timeout_ms")

    cond do
      is_nil(name) ->
        {:error, {:invalid_step, "step name is missing"}}

      is_nil(module) ->
        {:error, {:invalid_step, "step module is missing"}}

      true ->
        {:ok,
         %{
           name: to_string(name),
           type: normalize_step_type(fetch(step, "type"), "skill"),
           module: module,
           inputs: inputs,
           timeout_ms: timeout_ms
         }}
    end
  end

  defp normalize_step(other),
    do: {:error, {:invalid_step, "step must be a map, got: #{inspect(other)}"}}

  defp resolve_module(module) when is_atom(module), do: {:ok, module}

  defp resolve_module(module) when is_binary(module) do
    qualified =
      if String.starts_with?(module, "Elixir.") do
        module
      else
        "Elixir." <> module
      end

    try do
      resolved = String.to_existing_atom(qualified)

      if Code.ensure_loaded?(resolved) do
        {:ok, resolved}
      else
        {:error, {:module_not_loaded, module}}
      end
    rescue
      ArgumentError ->
        {:error, {:module_not_loaded, module}}
    end
  end

  defp resolve_module(other), do: {:error, {:invalid_module, other}}

  defp ensure_skill_callback(module) do
    if function_exported?(module, :handle_workflow_step, 2) do
      :ok
    else
      {:error, {:invalid_skill_module, module}}
    end
  end

  defp run_skill(skill_module, resolved_inputs, state, step_meta) do
    case run_skill_call(skill_module, resolved_inputs, state, step_meta.timeout_ms) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, {:skill_failed, to_string(step_meta.module), reason}}

      {:ok, other} ->
        {:error, {:invalid_skill_result, to_string(step_meta.module), other}}

      {:error, {:timeout, timeout_ms}} ->
        {:error, {:skill_timeout, to_string(step_meta.module), timeout_ms}}
    end
  end

  defp run_skill_call(skill_module, resolved_inputs, state, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    task =
      Task.async(fn ->
        skill_module.handle_workflow_step(resolved_inputs, state)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      _ -> {:error, {:timeout, timeout_ms}}
    end
  end

  defp run_skill_call(skill_module, resolved_inputs, state, _timeout_ms) do
    {:ok, skill_module.handle_workflow_step(resolved_inputs, state)}
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
      fetch_context_value(context, "publish_events")

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
