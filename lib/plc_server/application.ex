defmodule PlcServer.Application do
  @moduledoc "构建应用监督树，并根据配置启动 PLC 驱动进程。"
  use Application

  @doc "OTP 应用启动回调：启动注册表、块监督器和已配置的 PLC 驱动。"
  @impl true
  def start(_type, _args) do
    with {:ok, devices} <- configured_devices(),
         {:ok, mqtt_config} <- PlcServer.MqttAdapter.config(),
         {:ok, http_config} <- PlcServer.Http.config() do
      children =
        [
          {Registry, keys: :unique, name: PlcServer.Registry},
          {DynamicSupervisor, name: PlcServer.BlockSupervisor, strategy: :one_for_one},
          {DynamicSupervisor, name: PlcServer.DeviceSupervisor, strategy: :one_for_one},
          PlcServer.DeviceManager
        ]

      case Supervisor.start_link(children, strategy: :one_for_one, name: PlcServer.Supervisor) do
        {:ok, supervisor} ->
          with :ok <- start_devices(devices),
               :ok <- start_mqtt(supervisor, mqtt_config),
               :ok <- start_http(supervisor, http_config) do
            {:ok, supervisor}
          else
            error ->
              Supervisor.stop(supervisor)
              error
          end

        error ->
          error
      end
    end
  end

  @doc "生成带独立监督器 ID 的设备子进程配置。"
  def device_specs do
    with {:ok, devices} <- configured_devices() do
      {:ok,
       Enum.map(devices, fn opts ->
         Supervisor.child_spec({PlcService.Device, opts}, id: {:plc_device, opts[:id]})
       end)}
    end
  end

  @doc "读取并验证启动时的设备配置。"
  def configured_devices do
    with {:ok, saved} <- PlcServer.DeviceConfig.load() do
      if saved == nil, do: default_devices(), else: validate_devices(saved)
    end
  end

  defp default_devices do
    case Application.get_env(:plc_server, :devices) do
      nil -> legacy_device()
      [] -> legacy_device()
      devices -> validate_devices(devices)
    end
  end

  @doc "验证一台设备的运行时配置。"
  def normalize_device(opts) do
    case validate_devices([opts]) do
      {:ok, [device]} -> {:ok, device}
      error -> error
    end
  end

  defp start_devices(devices) do
    Enum.reduce_while(devices, :ok, fn opts, :ok ->
      case PlcServer.DeviceManager.bootstrap_device(opts) do
        {:ok, _pid} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp start_mqtt(_supervisor, nil), do: :ok

  defp start_mqtt(supervisor, config) do
    case Supervisor.start_child(supervisor, {PlcServer.MqttAdapter, config}) do
      {:ok, _pid} -> :ok
      error -> error
    end
  end

  defp start_http(_supervisor, nil), do: :ok

  defp start_http(supervisor, config) do
    spec = Bandit.child_spec(plug: PlcServer.HttpRouter, ip: config.ip, port: config.port)

    case Supervisor.start_child(supervisor, spec) do
      {:ok, _pid} -> :ok
      error -> error
    end
  end

  defp legacy_device do
    case System.get_env("PLC_HOST") do
      nil ->
        {:ok, []}

      host ->
        with {rack, ""} <- Integer.parse(System.get_env("PLC_RACK", "0")),
             {slot, ""} <- Integer.parse(System.get_env("PLC_SLOT", "1")) do
          validate_devices([
            [id: System.get_env("PLC_ID", "plc1"), host: host, rack: rack, slot: slot]
          ])
        else
          _ -> {:error, :invalid_device_config}
        end
    end
  end

  defp validate_devices(devices) when is_list(devices) do
    devices
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn opts, {:ok, valid, ids} ->
      opts = if is_map(opts), do: Map.to_list(opts), else: opts

      if is_list(opts) and Keyword.keyword?(opts) do
        id = opts[:id]
        host = opts[:host]
        rack = opts[:rack]
        slot = opts[:slot]

        cond do
          not (is_binary(id) and id != "" and is_binary(host) and host != "" and
                 is_integer(rack) and rack in 0..255 and is_integer(slot) and slot in 0..255) ->
            {:halt, {:error, :invalid_device_config}}

          not valid_options?(opts) ->
            {:halt, {:error, :invalid_device_config}}

          MapSet.member?(ids, id) ->
            {:halt, {:error, {:duplicate_device_id, id}}}

          true ->
            {:cont,
             {:ok,
              [
                Keyword.take(opts, [
                  :id,
                  :host,
                  :rack,
                  :slot,
                  :timeout,
                  :max_consecutive_timeouts,
                  :port_path
                ])
                | valid
              ], MapSet.put(ids, id)}}
        end
      else
        {:halt, {:error, :invalid_device_config}}
      end
    end)
    |> case do
      {:ok, valid, _} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp validate_devices(_), do: {:error, :invalid_device_config}

  defp valid_options?(opts) do
    timeout = opts[:timeout]
    max_timeouts = opts[:max_consecutive_timeouts]
    port_path = opts[:port_path]

    (timeout == nil or (is_integer(timeout) and timeout > 0)) and
      (max_timeouts == nil or (is_integer(max_timeouts) and max_timeouts > 0)) and
      (port_path == nil or (is_binary(port_path) and port_path != ""))
  end
end
