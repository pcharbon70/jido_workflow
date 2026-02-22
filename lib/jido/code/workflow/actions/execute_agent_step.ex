defmodule Jido.Code.Workflow.Actions.ExecuteAgentStep do
  @moduledoc """
  Executes compiled agent workflow steps.

  Agent step metadata includes:
  - target agent module
  - input bindings
  - optional pre-actions and post-actions
  - optional callback signal publication after completion
  - execution mode (`sync` or `async`)
  """

  require Logger

  alias Jido.Code.Workflow.ArgumentResolver
  alias Jido.Code.Workflow.Broadcaster
  alias Jido.Signal
  alias Jido.Signal.Bus

  use Jido.Action,
    name: "workflow_execute_agent_step",
    description: "Execute a compiled workflow agent step",
    schema: [
      step: [type: :map, required: true]
    ]

  @default_async_timeout 60_000
  @workflow_context_key "__workflow"
  @broadcast_event_step_started "step_started"
  @broadcast_event_step_completed "step_completed"
  @broadcast_event_step_failed "step_failed"
  @broadcast_event_agent_state "agent_state"

  @impl true
  def run(%{step: step} = params, _context) do
    state =
      params
      |> extract_runtime_state()
      |> ArgumentResolver.normalize_state()

    with {:ok, step_meta} <- normalize_step(step) do
      _ = maybe_broadcast_step_started(state, step_meta)
      _ = maybe_broadcast_agent_state(state, step_meta, "running")

      case execute_step_agent(step_meta, state) do
        {:ok, final_result} ->
          _ = maybe_emit_callback_signal(step_meta, final_result, state)
          _ = maybe_broadcast_step_completed(state, step_meta, final_result)
          _ = maybe_broadcast_agent_state(state, step_meta, "completed")
          {:ok, ArgumentResolver.put_result(state, step_meta.name, final_result)}

        {:error, reason} = error ->
          _ = maybe_broadcast_step_failed(state, step_meta, reason)

          _ =
            maybe_broadcast_agent_state(state, step_meta, "failed", %{"reason" => inspect(reason)})

          error
      end
    end
  end

  defp execute_step_agent(step_meta, state) do
    with {:ok, resolved_inputs} <- ArgumentResolver.resolve_inputs(step_meta.inputs, state),
         {:ok, pre_context} <- run_pre_actions(step_meta.pre_actions, state, resolved_inputs),
         {:ok, agent_result} <- execute_agent(step_meta, Map.merge(resolved_inputs, pre_context)) do
      run_post_actions(step_meta.post_actions, step_meta.name, state, agent_result)
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
    agent = fetch(step, "agent")
    inputs = fetch(step, "inputs") || %{}
    mode = normalize_mode(fetch(step, "mode"))
    pre_actions = fetch(step, "pre_actions")
    post_actions = fetch(step, "post_actions")
    callback_signal = fetch(step, "callback_signal")
    timeout_ms = fetch(step, "timeout_ms")

    with {:ok, timeout_ms} <- normalize_timeout(timeout_ms),
         {:ok, callback_signal} <- normalize_callback_signal(callback_signal),
         :ok <- validate_mode(mode),
         {:ok, normalized_pre_actions} <- normalize_hook_actions(pre_actions, :pre),
         {:ok, normalized_post_actions} <- normalize_hook_actions(post_actions, :post),
         :ok <- validate_name(name),
         :ok <- validate_agent(agent) do
      {:ok,
       %{
         name: to_string(name),
         type: normalize_step_type(fetch(step, "type"), "agent"),
         agent: agent,
         inputs: inputs,
         mode: mode,
         callback_signal: callback_signal,
         timeout_ms: timeout_ms,
         pre_actions: normalized_pre_actions,
         post_actions: normalized_post_actions
       }}
    end
  end

  defp normalize_step(other),
    do: {:error, {:invalid_step, "step must be a map, got: #{inspect(other)}"}}

  defp validate_name(name) when is_binary(name) and name != "", do: :ok
  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(_name), do: {:error, {:invalid_step, "step name is missing"}}

  defp validate_agent(agent) when is_binary(agent) and agent != "", do: :ok
  defp validate_agent(agent) when is_atom(agent), do: :ok
  defp validate_agent(_agent), do: {:error, {:invalid_step, "step agent is missing"}}

  defp validate_mode("sync"), do: :ok
  defp validate_mode("async"), do: :ok
  defp validate_mode(mode), do: {:error, {:invalid_mode, mode}}

  defp normalize_mode(nil), do: "sync"

  defp normalize_mode(mode) when is_atom(mode), do: mode |> Atom.to_string() |> String.downcase()
  defp normalize_mode(mode) when is_binary(mode), do: String.downcase(mode)
  defp normalize_mode(mode), do: mode

  defp normalize_timeout(nil), do: {:ok, nil}
  defp normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: {:ok, timeout}
  defp normalize_timeout(other), do: {:error, {:invalid_timeout, other}}

  defp normalize_callback_signal(nil), do: {:ok, nil}

  defp normalize_callback_signal(callback_signal)
       when is_binary(callback_signal) and callback_signal != "" do
    {:ok, callback_signal}
  end

  defp normalize_callback_signal(callback_signal) when is_atom(callback_signal) do
    {:ok, Atom.to_string(callback_signal)}
  end

  defp normalize_callback_signal(other), do: {:error, {:invalid_callback_signal, other}}

  defp normalize_hook_actions(nil, _phase), do: {:ok, []}

  defp normalize_hook_actions(actions, phase) when is_list(actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {action, index}, {:ok, acc} ->
      case normalize_hook_action(action, phase, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_hook_actions(other, phase), do: {:error, {:invalid_hook_actions, phase, other}}

  defp normalize_hook_action(action, phase, index) when is_map(action) do
    module = fetch(action, "module")
    inputs = fetch(action, "inputs") || %{}
    name = fetch(action, "name")
    timeout_ms = fetch(action, "timeout_ms")

    with :ok <- validate_hook_module(module, phase, index),
         {:ok, timeout_ms} <- normalize_timeout(timeout_ms) do
      {:ok,
       %{
         name: normalize_hook_name(name),
         module: module,
         inputs: inputs,
         timeout_ms: timeout_ms
       }}
    end
  end

  defp normalize_hook_action(other, phase, index),
    do: {:error, {:invalid_hook_action, phase, index, other}}

  defp validate_hook_module(module, _phase, _index) when is_binary(module) and module != "",
    do: :ok

  defp validate_hook_module(module, _phase, _index) when is_atom(module) and not is_nil(module),
    do: :ok

  defp validate_hook_module(_module, phase, index),
    do: {:error, {:invalid_hook_action_module, phase, index}}

  defp normalize_hook_name(nil), do: nil
  defp normalize_hook_name(name) when is_binary(name), do: name
  defp normalize_hook_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_hook_name(_name), do: nil

  defp run_pre_actions([], _state, _resolved_inputs), do: {:ok, %{}}

  defp run_pre_actions(pre_actions, state, resolved_inputs) do
    Enum.reduce_while(pre_actions, {:ok, %{}}, fn action_meta, {:ok, acc} ->
      state_with_context = merge_state_inputs(state, Map.merge(resolved_inputs, acc))

      with {:ok, action_inputs} <-
             ArgumentResolver.resolve_inputs(action_meta.inputs, state_with_context),
           {:ok, action_module} <- resolve_module(action_meta.module),
           {:ok, action_result} <-
             run_module(
               action_module,
               action_inputs,
               action_meta.timeout_ms,
               %{workflow_hook: "pre", workflow_hook_step: action_name(action_meta)}
             ) do
        {:cont, {:ok, Map.merge(acc, normalize_result(action_result))}}
      else
        {:error, reason} ->
          {:halt, {:error, {:pre_action_failed, action_name(action_meta), reason}}}
      end
    end)
  end

  defp execute_agent(%{mode: "sync"} = step_meta, resolved_inputs),
    do: run_agent(step_meta, resolved_inputs)

  defp execute_agent(%{mode: "async"} = step_meta, resolved_inputs) do
    timeout = step_meta.timeout_ms || @default_async_timeout
    task = Task.async(fn -> run_agent(step_meta, resolved_inputs) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:exit, reason} ->
        {:error, {:agent_async_exit, step_meta.agent, reason}}

      nil ->
        {:error, {:agent_timeout, step_meta.agent, timeout}}
    end
  end

  defp run_agent(step_meta, resolved_inputs) do
    with {:ok, agent_module} <- resolve_module(step_meta.agent),
         {:ok, result} <-
           run_module(agent_module, resolved_inputs, step_meta.timeout_ms, %{
             workflow_step: step_meta.name,
             workflow_agent: step_meta.agent
           }) do
      {:ok, result}
    else
      {:error, {:module_not_loaded, agent}} ->
        {:error, {:agent_not_loaded, agent}}

      {:error, {:invalid_module, module}} ->
        {:error, {:invalid_agent, module}}

      {:error, reason} ->
        {:error, {:agent_failed, step_meta.agent, reason}}
    end
  end

  defp run_post_actions([], _step_name, _state, agent_result), do: {:ok, agent_result}

  defp run_post_actions(post_actions, step_name, state, agent_result) do
    initial = normalize_result(agent_result)

    Enum.reduce_while(post_actions, {:ok, initial}, fn action_meta, {:ok, acc} ->
      state_with_result =
        state
        |> merge_state_inputs(acc)
        |> ArgumentResolver.put_result(step_name, acc)

      with {:ok, action_inputs} <-
             ArgumentResolver.resolve_inputs(action_meta.inputs, state_with_result),
           {:ok, action_module} <- resolve_module(action_meta.module),
           {:ok, action_result} <-
             run_module(
               action_module,
               action_inputs,
               action_meta.timeout_ms,
               %{workflow_hook: "post", workflow_hook_step: action_name(action_meta)}
             ) do
        {:cont, {:ok, Map.merge(acc, normalize_result(action_result))}}
      else
        {:error, reason} ->
          {:halt, {:error, {:post_action_failed, action_name(action_meta), reason}}}
      end
    end)
  end

  defp merge_state_inputs(state, additions) when is_map(state) and is_map(additions) do
    merged =
      state
      |> Map.get("inputs", %{})
      |> Map.merge(stringify_keys(additions))

    Map.put(state, "inputs", merged)
  end

  defp merge_state_inputs(state, _additions), do: state

  defp normalize_result(result) when is_map(result), do: stringify_keys(result)
  defp normalize_result(result), do: %{"value" => result}

  defp run_module(target_module, inputs, timeout_ms, context) do
    opts =
      case timeout_ms do
        timeout when is_integer(timeout) and timeout >= 0 -> [timeout: timeout]
        _ -> []
      end

    case Jido.Exec.run(target_module, atomize_top_level_keys(inputs), context, opts) do
      {:ok, result} -> {:ok, result}
      {:ok, result, extra} -> {:ok, %{result: result, extra: extra}}
      {:error, reason} -> {:error, {:execution_failed, reason}}
    end
  end

  defp maybe_emit_callback_signal(%{callback_signal: nil}, _result, _state), do: :ok

  defp maybe_emit_callback_signal(%{callback_signal: callback_signal} = step_meta, result, state)
       when is_binary(callback_signal) do
    signal =
      Signal.new!(
        callback_signal,
        %{
          "step_name" => step_meta.name,
          "agent" => to_string(step_meta.agent),
          "mode" => step_meta.mode,
          "result" => stringify_keys(result)
        },
        source: callback_source(step_meta.name, state)
      )

    case Bus.publish(callback_bus(state), [signal]) do
      {:ok, _published} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to publish callback signal #{inspect(callback_signal)}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Failed to publish callback signal #{inspect(callback_signal)}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp callback_bus(state) do
    context_bus(workflow_context(state))
  end

  defp callback_source(step_name, state) do
    case fetch_context_value(workflow_context(state), "source") do
      source when is_binary(source) and source != "" ->
        source <> "/step/" <> step_name <> "/callback"

      _ ->
        "/jido_workflow/workflow/step/#{step_name}/callback"
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

  defp maybe_broadcast_agent_state(state, step_meta, state_name, details \\ %{}) do
    if broadcast_event_enabled?(state, @broadcast_event_agent_state) do
      with {:ok, workflow_id, run_id} <- workflow_run_identifiers(state) do
        agent_state =
          %{
            "step" => step_payload(step_meta),
            "mode" => step_meta.mode,
            "state" => state_name
          }
          |> Map.merge(stringify_keys(details))

        Broadcaster.broadcast_agent_state(
          workflow_id,
          run_id,
          step_meta.agent,
          agent_state,
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

  defp atomize_top_level_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      converted_key =
        case key do
          atom when is_atom(atom) ->
            atom

          binary when is_binary(binary) ->
            try do
              String.to_existing_atom(binary)
            rescue
              ArgumentError -> binary
            end

          other ->
            other
        end

      Map.put(acc, converted_key, value)
    end)
  end

  defp stringify_keys(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, item} ->
      {to_string(key), stringify_keys(item)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp action_name(%{name: name, module: _module}) when is_binary(name) and name != "", do: name
  defp action_name(%{module: module}), do: to_string(module)

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
