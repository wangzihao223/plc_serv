defmodule PlcServer.DeviceManager do
  @moduledoc "串行管理运行时 PLC 设备的增删、更新和配置持久化。"
  use GenServer

  @doc "启动设备管理进程。"
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "启动静态或已保存的设备，不重新写入快照。"
  def bootstrap_device(opts), do: GenServer.call(__MODULE__, {:bootstrap, opts})

  @doc "添加设备并保存配置。"
  def add_device(opts), do: GenServer.call(__MODULE__, {:add, opts})

  @doc "移除设备并保存配置，不删除其块订阅。"
  def remove_device(plc), do: GenServer.call(__MODULE__, {:remove, plc})

  @doc "替换并保存设备配置，失败时尝试恢复旧设备。"
  def update_device(plc, opts), do: GenServer.call(__MODULE__, {:update, plc, opts})

  @doc "列出当前运行时管理的 PLC 配置。"
  def list_devices, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(:ok) do
    with {:ok, configs} <- PlcServer.Application.configured_devices() do
      saved = Map.new(configs, fn opts -> {opts[:id], opts} end)
      {:ok, Map.merge(saved, managed_devices())}
    end
  end

  @impl true
  def handle_call({:bootstrap, opts}, _from, state) do
    {result, state} = add(opts, state, false)
    {:reply, result, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, state |> Map.values() |> Enum.sort_by(&Keyword.fetch!(&1, :id)), state}
  end

  def handle_call({:add, opts}, _from, state) do
    {result, state} = add(opts, state, true)
    {:reply, result, state}
  end

  def handle_call({:remove, plc}, _from, state) do
    result =
      with {:ok, {pid, _}} <- lookup_device(plc),
           :ok <- ensure_managed(pid),
           next = Map.delete(state, plc),
           :ok <- persist(next) do
        case remove_device_process(pid) do
          :ok -> {:ok, next}
          error -> {:error, restore_snapshot(error, state)}
        end
      end

    case result do
      {:ok, next} -> {:reply, :ok, next}
      {:error, {:error, _} = error} -> {:reply, error, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, plc, opts}, _from, state) do
    result =
      with {:ok, {pid, old_config}} <- lookup_device(plc),
           {:ok, config} <- PlcServer.Application.normalize_device(put_id(opts, plc)),
           :ok <- ensure_managed(pid),
           next = Map.put(state, plc, config),
           :ok <- persist(next) do
        case replace_device(pid, old_config, config) do
          {:ok, new_pid} -> {:ok, new_pid, next}
          error -> {:error, restore_snapshot(error, state)}
        end
      end

    case result do
      {:ok, new_pid, next} -> {:reply, {:ok, new_pid}, next}
      {:error, {:error, _} = error} -> {:reply, error, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp add(opts, state, persist?) do
    with {:ok, config} <- PlcServer.Application.normalize_device(opts),
         :ok <- ensure_absent(config[:id]),
         next = Map.put(state, config[:id], config),
         :ok <- maybe_persist(next, persist?) do
      case start_device(config) do
        {:ok, pid} -> {{:ok, pid}, next}
        error -> {if(persist?, do: restore_snapshot(error, state), else: error), state}
      end
    else
      error -> {error, state}
    end
  end

  defp remove_device_process(pid) do
    with :ok <- PlcService.Device.prepare_shutdown(pid, :device_removed) do
      DynamicSupervisor.terminate_child(PlcServer.DeviceSupervisor, pid)
    end
  end

  defp replace_device(pid, old_config, config) do
    with :ok <- PlcService.Device.prepare_shutdown(pid, :device_reconfigured),
         :ok <- DynamicSupervisor.terminate_child(PlcServer.DeviceSupervisor, pid) do
      case start_device(config) do
        {:ok, new_pid} ->
          {:ok, new_pid}

        {:error, reason} ->
          case start_device(old_config) do
            {:ok, _} ->
              {:error, {:update_failed, reason}}

            {:error, rollback_reason} ->
              {:error, {:update_failed, reason, rollback_reason}}
          end
      end
    end
  end

  defp start_device(opts) do
    spec = Supervisor.child_spec({PlcService.Device, opts}, id: {:plc_device, opts[:id]})
    DynamicSupervisor.start_child(PlcServer.DeviceSupervisor, spec)
  end

  defp maybe_persist(next, true), do: persist(next)
  defp maybe_persist(_, false), do: :ok

  defp persist(state) do
    state
    |> Map.values()
    |> Enum.sort_by(&Keyword.fetch!(&1, :id))
    |> PlcServer.DeviceConfig.save()
  end

  defp restore_snapshot(error, state) do
    case persist(state) do
      :ok -> error
      rollback_error -> {:error, {:config_rollback_failed, error, rollback_error}}
    end
  end

  defp lookup_device(plc) do
    case Registry.lookup(PlcServer.Registry, {:device, plc}) do
      [{pid, opts}] -> {:ok, {pid, opts}}
      [] -> {:error, :unknown_plc}
    end
  end

  defp ensure_absent(plc) do
    case Registry.lookup(PlcServer.Registry, {:device, plc}) do
      [] -> :ok
      [_] -> {:error, :already_exists}
    end
  end

  defp ensure_managed(pid) do
    if Enum.any?(DynamicSupervisor.which_children(PlcServer.DeviceSupervisor), fn
         {_, ^pid, _, _} -> true
         _ -> false
       end) do
      :ok
    else
      {:error, :unmanaged_device}
    end
  end

  defp managed_devices do
    Enum.reduce(DynamicSupervisor.which_children(PlcServer.DeviceSupervisor), %{}, fn
      {_, pid, _, _}, devices when is_pid(pid) ->
        case Enum.find(Registry.keys(PlcServer.Registry, pid), &match?({:device, _}, &1)) do
          {:device, id} ->
            case Registry.lookup(PlcServer.Registry, {:device, id}) do
              [{^pid, opts}] -> Map.put(devices, id, opts)
              _ -> devices
            end

          nil ->
            devices
        end

      _, devices ->
        devices
    end)
  end

  defp put_id(opts, plc) when is_list(opts), do: Keyword.put(opts, :id, plc)
  defp put_id(opts, plc) when is_map(opts), do: Map.put(opts, :id, plc)
  defp put_id(_, _), do: :invalid_device_config
end
