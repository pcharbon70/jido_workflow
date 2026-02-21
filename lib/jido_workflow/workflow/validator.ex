defmodule JidoWorkflow.Workflow.Validator do
  @moduledoc """
  Validates and normalizes workflow definitions into typed structs.
  """

  alias JidoWorkflow.Workflow.Definition

  alias JidoWorkflow.Workflow.Definition.{
    Input,
    RetryPolicy,
    Return,
    Settings,
    Signals,
    Step,
    Trigger
  }

  alias JidoWorkflow.Workflow.StepTypeRegistry
  alias JidoWorkflow.Workflow.TriggerTypeRegistry
  alias JidoWorkflow.Workflow.ValidationError

  @name_regex ~r/^[a-z][a-z0-9_]*$/
  @version_regex ~r/^\d+\.\d+\.\d+$/
  @input_types ~w(string integer boolean map list)
  @retry_backoff_types ~w(linear exponential constant)
  @on_failure_types ~w(compensate halt continue)
  @agent_modes ~w(sync async)
  @publish_events ~w(step_started step_completed step_failed workflow_complete agent_state)
  @definition_keys ~w(
    name
    version
    description
    enabled
    inputs
    triggers
    settings
    signals
    steps
    error_handling
    return
  )
  @signals_keys ~w(topic publish_events)
  @input_keys ~w(name type required default description)
  @trigger_generic_keys ~w(type patterns events schedule command debounce_ms)
  @file_system_trigger_keys ~w(type patterns events debounce_ms)
  @git_hook_trigger_keys ~w(type events)
  @signal_trigger_keys ~w(type patterns)
  @scheduled_trigger_keys ~w(type schedule)
  @manual_trigger_keys ~w(type command)
  @step_generic_keys ~w(
    name
    type
    module
    agent
    workflow
    callback_signal
    inputs
    outputs
    depends_on
    async
    optional
    mode
    timeout_ms
    max_retries
    pre_actions
    post_actions
    condition
    parallel
  )
  @action_step_keys ~w(
    name
    type
    module
    inputs
    outputs
    depends_on
    async
    optional
    timeout_ms
    max_retries
  )
  @agent_step_keys ~w(
    name
    type
    agent
    callback_signal
    inputs
    depends_on
    mode
    timeout_ms
    pre_actions
    post_actions
  )
  @skill_step_keys ~w(
    name
    type
    module
    inputs
    outputs
    depends_on
    async
    optional
    timeout_ms
    max_retries
  )
  @sub_workflow_step_keys ~w(
    name
    type
    workflow
    inputs
    depends_on
    condition
    parallel
    timeout_ms
  )
  @settings_keys ~w(max_concurrency timeout_ms retry_policy on_failure)
  @retry_policy_keys ~w(max_retries backoff base_delay_ms)
  @error_handler_keys ~w(handler action inputs)
  @return_keys ~w(value transform)

  @spec validate(map()) :: {:ok, Definition.t()} | {:error, [ValidationError.t()]}
  def validate(attrs) when is_map(attrs) do
    errors = reject_unknown_keys(attrs, @definition_keys, [], [])

    {name, errors} =
      required_string(attrs, :name, ["name"], @name_regex, "must match ^[a-z][a-z0-9_]*$", errors)

    {version, errors} =
      required_string(
        attrs,
        :version,
        ["version"],
        @version_regex,
        "must be semver like 1.0.0",
        errors
      )

    trigger_types = TriggerTypeRegistry.supported_types()
    step_types = StepTypeRegistry.supported_types()

    {description, errors} = optional_string(attrs, :description, ["description"], errors)
    {enabled, errors} = optional_boolean(attrs, :enabled, ["enabled"], true, errors)
    {inputs, errors} = validate_inputs(get(attrs, :inputs, []), ["inputs"], errors)

    {triggers, errors} =
      validate_triggers(get(attrs, :triggers, []), ["triggers"], trigger_types, errors)

    {steps, errors} = validate_steps(get(attrs, :steps, []), ["steps"], step_types, errors)
    {settings, errors} = validate_settings(get(attrs, :settings), ["settings"], errors)
    {signals, errors} = validate_signal_policy(attrs, errors)

    {error_handling, errors} =
      validate_error_handling(get(attrs, :error_handling, []), ["error_handling"], errors)

    {return_config, errors} = validate_return(get(attrs, :return), ["return"], errors)

    definition = %Definition{
      name: name || "",
      version: version || "",
      description: description,
      enabled: enabled,
      inputs: inputs,
      triggers: triggers,
      settings: settings,
      signals: signals,
      steps: steps,
      error_handling: error_handling,
      return: return_config
    }

    case errors do
      [] -> {:ok, definition}
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(other) do
    {:error,
     [
       %ValidationError{
         path: [],
         code: :invalid_type,
         message: "definition must be a map, got: #{inspect(other)}"
       }
     ]}
  end

  defp validate_inputs(inputs, path, errors) when is_list(inputs) do
    inputs
    |> Enum.with_index()
    |> Enum.reduce({[], errors}, fn {input, index}, {acc, err_acc} ->
      current = path ++ [Integer.to_string(index)]

      case normalize_input(input, current, err_acc) do
        {nil, next_errors} ->
          {acc, next_errors}

        {normalized, next_errors} ->
          {[normalized | acc], next_errors}
      end
    end)
    |> then(fn {normalized, err_acc} -> {Enum.reverse(normalized), err_acc} end)
  end

  defp validate_inputs(_, path, errors) do
    {[], error(errors, path, :invalid_type, "inputs must be a list")}
  end

  defp normalize_input(input, path, errors) when is_map(input) do
    errors = reject_unknown_keys(input, @input_keys, path, errors)

    {name, errors} =
      required_string(input, :name, path ++ ["name"], nil, "name is required", errors)

    {type, errors} =
      required_string(input, :type, path ++ ["type"], nil, "type is required", errors)

    errors = maybe_add_inclusion_error(errors, type, @input_types, path ++ ["type"])
    {required, errors} = optional_boolean(input, :required, path ++ ["required"], false, errors)
    default = get(input, :default)
    {description, errors} = optional_string(input, :description, path ++ ["description"], errors)

    normalized = %Input{
      name: name || "",
      type: type || "",
      required: required,
      default: default,
      description: description
    }

    {normalized, errors}
  end

  defp normalize_input(_input, path, errors) do
    {nil, error(errors, path, :invalid_type, "input must be a map")}
  end

  defp validate_triggers(triggers, path, trigger_types, errors) when is_list(triggers) do
    triggers
    |> Enum.with_index()
    |> Enum.reduce({[], errors}, fn {trigger, index}, {acc, err_acc} ->
      current = path ++ [Integer.to_string(index)]

      case normalize_trigger(trigger, current, trigger_types, err_acc) do
        {nil, next_errors} ->
          {acc, next_errors}

        {normalized, next_errors} ->
          {[normalized | acc], next_errors}
      end
    end)
    |> then(fn {normalized, err_acc} -> {Enum.reverse(normalized), err_acc} end)
  end

  defp validate_triggers(_, path, _trigger_types, errors) do
    {[], error(errors, path, :invalid_type, "triggers must be a list")}
  end

  defp normalize_trigger(trigger, path, trigger_types, errors) when is_map(trigger) do
    {type, errors} =
      required_string(trigger, :type, path ++ ["type"], nil, "type is required", errors)

    errors = reject_unknown_keys(trigger, trigger_allowed_keys(type), path, errors)
    errors = maybe_add_inclusion_error(errors, type, trigger_types, path ++ ["type"])
    {patterns, errors} = optional_string_list(trigger, :patterns, path ++ ["patterns"], errors)
    {events, errors} = optional_string_list(trigger, :events, path ++ ["events"], errors)
    {schedule, errors} = optional_string(trigger, :schedule, path ++ ["schedule"], errors)
    {command, errors} = optional_string(trigger, :command, path ++ ["command"], errors)

    {debounce_ms, errors} =
      optional_integer(trigger, :debounce_ms, path ++ ["debounce_ms"], errors)

    errors = validate_trigger_requirements(errors, type, patterns, schedule, path)

    normalized = %Trigger{
      type: type || "",
      patterns: patterns,
      events: events,
      schedule: schedule,
      command: command,
      debounce_ms: debounce_ms
    }

    {normalized, errors}
  end

  defp normalize_trigger(_trigger, path, _trigger_types, errors) do
    {nil, error(errors, path, :invalid_type, "trigger must be a map")}
  end

  defp validate_trigger_requirements(errors, "file_system", patterns, _schedule, path) do
    if is_list(patterns) and patterns != [] do
      errors
    else
      error(
        errors,
        path ++ ["patterns"],
        :required,
        "patterns is required for file_system triggers"
      )
    end
  end

  defp validate_trigger_requirements(errors, "signal", patterns, _schedule, path) do
    if is_list(patterns) and patterns != [] do
      errors
    else
      error(errors, path ++ ["patterns"], :required, "patterns is required for signal triggers")
    end
  end

  defp validate_trigger_requirements(errors, "scheduled", _patterns, nil, path) do
    error(errors, path ++ ["schedule"], :required, "schedule is required for scheduled triggers")
  end

  defp validate_trigger_requirements(errors, _type, _patterns, _schedule, _path), do: errors

  defp validate_steps(steps, path, step_types, errors) when is_list(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce({[], errors}, fn {step, index}, {acc, err_acc} ->
      current = path ++ [Integer.to_string(index)]

      case normalize_step(step, current, step_types, err_acc) do
        {nil, next_errors} ->
          {acc, next_errors}

        {normalized, next_errors} ->
          {[normalized | acc], next_errors}
      end
    end)
    |> then(fn {normalized, err_acc} -> {Enum.reverse(normalized), err_acc} end)
  end

  defp validate_steps(_, path, _step_types, errors) do
    {[], error(errors, path, :invalid_type, "steps must be a list")}
  end

  defp normalize_step(step, path, step_types, errors) when is_map(step) do
    {name, errors} =
      required_string(step, :name, path ++ ["name"], nil, "name is required", errors)

    {type, errors} =
      required_string(step, :type, path ++ ["type"], nil, "type is required", errors)

    errors = reject_unknown_keys(step, step_allowed_keys(type, step_types), path, errors)
    errors = maybe_add_inclusion_error(errors, type, step_types, path ++ ["type"])
    {module, errors} = optional_string(step, :module, path ++ ["module"], errors)
    {agent, errors} = optional_string(step, :agent, path ++ ["agent"], errors)
    {workflow, errors} = optional_string(step, :workflow, path ++ ["workflow"], errors)

    {callback_signal, errors} =
      optional_string(step, :callback_signal, path ++ ["callback_signal"], errors)

    {outputs, errors} = optional_string_list(step, :outputs, path ++ ["outputs"], errors)
    {depends_on, errors} = optional_string_list(step, :depends_on, path ++ ["depends_on"], errors)
    {async?, errors} = optional_boolean(step, :async, path ++ ["async"], nil, errors)
    {optional?, errors} = optional_boolean(step, :optional, path ++ ["optional"], nil, errors)
    {mode, errors} = optional_string(step, :mode, path ++ ["mode"], errors)
    {timeout_ms, errors} = optional_integer(step, :timeout_ms, path ++ ["timeout_ms"], errors)
    {max_retries, errors} = optional_integer(step, :max_retries, path ++ ["max_retries"], errors)
    {pre_actions, errors} = optional_map_list(step, :pre_actions, path ++ ["pre_actions"], errors)

    {post_actions, errors} =
      optional_map_list(step, :post_actions, path ++ ["post_actions"], errors)

    {condition, errors} = optional_string(step, :condition, path ++ ["condition"], errors)
    {parallel, errors} = optional_boolean(step, :parallel, path ++ ["parallel"], nil, errors)
    {inputs, errors} = optional_map_or_list(step, :inputs, path ++ ["inputs"], errors)

    errors =
      errors
      |> validate_step_requirements(type, module, agent, workflow, path)
      |> maybe_add_inclusion_error(mode, @agent_modes, path ++ ["mode"])

    normalized = %Step{
      name: name || "",
      type: type || "",
      module: module,
      agent: agent,
      workflow: workflow,
      callback_signal: callback_signal,
      inputs: inputs,
      outputs: outputs,
      depends_on: depends_on,
      async: async?,
      optional: optional?,
      mode: mode,
      timeout_ms: timeout_ms,
      max_retries: max_retries,
      pre_actions: pre_actions,
      post_actions: post_actions,
      condition: condition,
      parallel: parallel
    }

    {normalized, errors}
  end

  defp normalize_step(_step, path, _step_types, errors) do
    {nil, error(errors, path, :invalid_type, "step must be a map")}
  end

  defp validate_step_requirements(errors, "action", nil, _agent, _workflow, path) do
    error(errors, path ++ ["module"], :required, "module is required for action steps")
  end

  defp validate_step_requirements(errors, "skill", nil, _agent, _workflow, path) do
    error(errors, path ++ ["module"], :required, "module is required for skill steps")
  end

  defp validate_step_requirements(errors, "agent", _module, nil, _workflow, path) do
    error(errors, path ++ ["agent"], :required, "agent is required for agent steps")
  end

  defp validate_step_requirements(errors, "sub_workflow", _module, _agent, nil, path) do
    error(errors, path ++ ["workflow"], :required, "workflow is required for sub_workflow steps")
  end

  defp validate_step_requirements(errors, _type, _module, _agent, _workflow, _path), do: errors

  defp step_allowed_keys("action", _step_types), do: @action_step_keys
  defp step_allowed_keys("agent", _step_types), do: @agent_step_keys
  defp step_allowed_keys("skill", _step_types), do: @skill_step_keys
  defp step_allowed_keys("sub_workflow", _step_types), do: @sub_workflow_step_keys

  defp step_allowed_keys(type, _step_types) when is_binary(type), do: @step_generic_keys

  defp step_allowed_keys(_type, _step_types), do: @step_generic_keys

  defp trigger_allowed_keys("file_system"), do: @file_system_trigger_keys
  defp trigger_allowed_keys("git_hook"), do: @git_hook_trigger_keys
  defp trigger_allowed_keys("signal"), do: @signal_trigger_keys
  defp trigger_allowed_keys("scheduled"), do: @scheduled_trigger_keys
  defp trigger_allowed_keys("manual"), do: @manual_trigger_keys
  defp trigger_allowed_keys(type) when is_binary(type), do: @trigger_generic_keys
  defp trigger_allowed_keys(_type), do: @trigger_generic_keys

  defp maybe_add_inclusion_error(errors, nil, _allowed, _path), do: errors

  defp maybe_add_inclusion_error(errors, value, allowed, path) do
    if value in allowed do
      errors
    else
      error(errors, path, :invalid_value, "must be one of: #{Enum.join(allowed, ", ")}")
    end
  end

  defp validate_settings(nil, _path, errors), do: {nil, errors}

  defp validate_settings(settings, path, errors) when is_map(settings) do
    errors = reject_unknown_keys(settings, @settings_keys, path, errors)

    {max_concurrency, errors} =
      optional_integer(settings, :max_concurrency, path ++ ["max_concurrency"], errors)

    errors =
      if max_concurrency && max_concurrency < 1 do
        error(errors, path ++ ["max_concurrency"], :invalid_value, "must be >= 1")
      else
        errors
      end

    {timeout_ms, errors} = optional_integer(settings, :timeout_ms, path ++ ["timeout_ms"], errors)

    errors =
      if timeout_ms && timeout_ms < 1_000 do
        error(errors, path ++ ["timeout_ms"], :invalid_value, "must be >= 1000")
      else
        errors
      end

    {retry_policy, errors} =
      validate_retry_policy(get(settings, :retry_policy), path ++ ["retry_policy"], errors)

    {on_failure, errors} = optional_string(settings, :on_failure, path ++ ["on_failure"], errors)

    errors =
      if on_failure && on_failure not in @on_failure_types do
        error(
          errors,
          path ++ ["on_failure"],
          :invalid_value,
          "must be one of: #{Enum.join(@on_failure_types, ", ")}"
        )
      else
        errors
      end

    {%Settings{
       max_concurrency: max_concurrency,
       timeout_ms: timeout_ms,
       retry_policy: retry_policy,
       on_failure: on_failure
     }, errors}
  end

  defp validate_settings(_, path, errors) do
    {nil, error(errors, path, :invalid_type, "settings must be a map")}
  end

  defp validate_retry_policy(nil, _path, errors), do: {nil, errors}

  defp validate_retry_policy(policy, path, errors) when is_map(policy) do
    errors = reject_unknown_keys(policy, @retry_policy_keys, path, errors)

    {max_retries, errors} =
      optional_integer(policy, :max_retries, path ++ ["max_retries"], errors)

    {backoff, errors} = optional_string(policy, :backoff, path ++ ["backoff"], errors)

    {base_delay_ms, errors} =
      optional_integer(policy, :base_delay_ms, path ++ ["base_delay_ms"], errors)

    errors =
      if max_retries && max_retries < 0 do
        error(errors, path ++ ["max_retries"], :invalid_value, "must be >= 0")
      else
        errors
      end

    errors =
      if backoff && backoff not in @retry_backoff_types do
        error(
          errors,
          path ++ ["backoff"],
          :invalid_value,
          "must be one of: #{Enum.join(@retry_backoff_types, ", ")}"
        )
      else
        errors
      end

    {%RetryPolicy{max_retries: max_retries, backoff: backoff, base_delay_ms: base_delay_ms},
     errors}
  end

  defp validate_retry_policy(_, path, errors) do
    {nil, error(errors, path, :invalid_type, "retry_policy must be a map")}
  end

  defp validate_signal_policy(attrs, errors) do
    signals_attrs = get(attrs, :signals)
    {signals, errors} = validate_signals(signals_attrs, ["signals"], errors)
    {signals, errors}
  end

  defp validate_signals(nil, _path, errors), do: {nil, errors}

  defp validate_signals(signals, path, errors) when is_map(signals) do
    errors = reject_unknown_keys(signals, @signals_keys, path, errors)
    {topic, errors} = optional_string(signals, :topic, path ++ ["topic"], errors)

    {publish_events, errors} =
      optional_string_list(signals, :publish_events, path ++ ["publish_events"], errors)

    errors = maybe_add_unsupported_event_error(errors, publish_events, path ++ ["publish_events"])

    {%Signals{topic: topic, publish_events: publish_events}, errors}
  end

  defp validate_signals(_, path, errors) do
    {nil, error(errors, path, :invalid_type, "signals must be a map")}
  end

  defp maybe_add_unsupported_event_error(errors, nil, _path), do: errors

  defp maybe_add_unsupported_event_error(errors, events, path) do
    if Enum.any?(events, &(&1 not in @publish_events)) do
      error(errors, path, :invalid_value, "contains unsupported event")
    else
      errors
    end
  end

  defp validate_error_handling(handlers, path, errors) when is_list(handlers) do
    handlers
    |> Enum.with_index()
    |> Enum.reduce({[], errors}, fn {handler, index}, {acc, err_acc} ->
      current = path ++ [Integer.to_string(index)]

      case normalize_error_handler(handler, current, err_acc) do
        {nil, next_errors} ->
          {acc, next_errors}

        {normalized, next_errors} ->
          {[normalized | acc], next_errors}
      end
    end)
    |> then(fn {normalized, err_acc} -> {Enum.reverse(normalized), err_acc} end)
  end

  defp validate_error_handling(_, path, errors) do
    {[], error(errors, path, :invalid_type, "error_handling must be a list")}
  end

  defp normalize_error_handler(handler, path, errors) when is_map(handler) do
    errors = reject_unknown_keys(handler, @error_handler_keys, path, errors)

    {handler_name, errors} =
      required_string(handler, :handler, path ++ ["handler"], nil, "handler is required", errors)

    {action, errors} = optional_string(handler, :action, path ++ ["action"], errors)
    {inputs, errors} = optional_map_or_list(handler, :inputs, path ++ ["inputs"], errors)
    errors = maybe_add_missing_compensation_action_error(errors, handler_name, action, path)

    {%{"handler" => handler_name, "action" => action, "inputs" => inputs}, errors}
  end

  defp normalize_error_handler(_handler, path, errors) do
    {nil, error(errors, path, :invalid_type, "error handler must be a map")}
  end

  defp maybe_add_missing_compensation_action_error(errors, handler_name, action, path) do
    if compensation_handler_name?(handler_name) and is_nil(action) do
      error(errors, path ++ ["action"], :required, "action is required for compensation handlers")
    else
      errors
    end
  end

  defp compensation_handler_name?(name) when is_binary(name) do
    String.starts_with?(name, "compensate:")
  end

  defp compensation_handler_name?(_name), do: false

  defp validate_return(nil, _path, errors), do: {nil, errors}

  defp validate_return(return_config, path, errors) when is_map(return_config) do
    errors = reject_unknown_keys(return_config, @return_keys, path, errors)

    {value, errors} = optional_string(return_config, :value, path ++ ["value"], errors)
    transform = get(return_config, :transform)

    errors =
      cond do
        is_nil(transform) -> errors
        is_binary(transform) -> errors
        true -> error(errors, path ++ ["transform"], :invalid_type, "transform must be a string")
      end

    {%Return{value: value, transform: transform}, errors}
  end

  defp validate_return(_, path, errors) do
    {nil, error(errors, path, :invalid_type, "return must be a map")}
  end

  defp required_string(attrs, key, path, regex, regex_message, errors) do
    case get(attrs, key) do
      value when is_binary(value) ->
        if regex && not Regex.match?(regex, value) do
          {value, error(errors, path, :invalid_format, regex_message)}
        else
          {value, errors}
        end

      nil ->
        {nil, error(errors, path, :required, "#{last(path)} is required")}

      _ ->
        {nil, error(errors, path, :invalid_type, "#{last(path)} must be a string")}
    end
  end

  defp optional_string(attrs, key, path, errors) do
    case get(attrs, key) do
      nil -> {nil, errors}
      value when is_binary(value) -> {value, errors}
      _ -> {nil, error(errors, path, :invalid_type, "#{last(path)} must be a string")}
    end
  end

  defp optional_string_list(attrs, key, path, errors) do
    case get(attrs, key) do
      nil ->
        {nil, errors}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {list, errors}
        else
          {nil, error(errors, path, :invalid_type, "#{last(path)} must be a list of strings")}
        end

      _ ->
        {nil, error(errors, path, :invalid_type, "#{last(path)} must be a list")}
    end
  end

  defp optional_map_list(attrs, key, path, errors) do
    case get(attrs, key) do
      nil ->
        {nil, errors}

      list when is_list(list) ->
        if Enum.all?(list, &is_map/1) do
          {list, errors}
        else
          {nil, error(errors, path, :invalid_type, "#{last(path)} must be a list of maps")}
        end

      _ ->
        {nil, error(errors, path, :invalid_type, "#{last(path)} must be a list")}
    end
  end

  defp optional_map_or_list(attrs, key, path, errors) do
    case get(attrs, key) do
      nil -> {nil, errors}
      value when is_map(value) -> {value, errors}
      value when is_list(value) -> {value, errors}
      _ -> {nil, error(errors, path, :invalid_type, "#{last(path)} must be a map or list")}
    end
  end

  defp optional_boolean(attrs, key, path, default, errors) do
    case get(attrs, key, default) do
      value when is_boolean(value) -> {value, errors}
      nil -> {nil, errors}
      _ -> {default, error(errors, path, :invalid_type, "#{last(path)} must be a boolean")}
    end
  end

  defp optional_integer(attrs, key, path, errors) do
    case get(attrs, key) do
      nil -> {nil, errors}
      value when is_integer(value) -> {value, errors}
      _ -> {nil, error(errors, path, :invalid_type, "#{last(path)} must be an integer")}
    end
  end

  defp error(errors, path, code, message) do
    [%ValidationError{path: path, code: code, message: message} | errors]
  end

  defp last(list) do
    case List.last(list) do
      nil -> "value"
      value -> value
    end
  end

  defp get(attrs, key), do: get(attrs, key, nil)

  defp get(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp reject_unknown_keys(attrs, allowed_keys, path, errors)
       when is_map(attrs) and is_list(allowed_keys) do
    attrs
    |> Map.keys()
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&(&1 in allowed_keys))
    |> Enum.sort()
    |> Enum.reduce(errors, fn key, acc ->
      error(acc, path ++ [key], :unknown_key, "unknown key: #{key}")
    end)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
