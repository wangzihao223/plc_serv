defmodule PlcServer.Block do
  @moduledoc "管理一个 DB 范围的共享轮询、快照比较和订阅者通知。"
  use GenServer, restart: :transient

  @doc "按 `{plc, db, offset, length, interval}` 启动并注册一个块进程。"
  def start_link(key: key) do
    GenServer.start_link(__MODULE__, key,
      name: {:via, Registry, {PlcServer.Registry, {:block, key}}}
    )
  end

  @doc "让调用进程订阅块变化；调用进程退出后自动取消订阅。"
  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})

  @doc "验证订阅参数并初始化块状态。"
  @impl true
  def init({plc, db, offset, length, interval} = key)
      when is_integer(db) and db in 0..65_535 and is_integer(offset) and
             offset in 0..2_147_483_647 and offset <= 2_147_483_648 - length and
             is_integer(length) and length in 1..65_536 and is_integer(interval) and
             interval >= 50 do
    init_state(key, plc, db, offset, length, interval, nil)
  end

  def init({plc, db, offset, length, interval, config} = key)
      when is_map(config) and is_integer(db) and db in 0..65_535 and is_integer(offset) and
             offset >= 0 and is_integer(length) and length in 1..65_536 and
             offset <= 2_147_483_648 - length and is_integer(interval) and
             interval >= 50 do
    init_state(key, plc, db, offset, length, interval, config)
  end

  # 无效参数会阻止块进程启动。
  def init(_), do: {:stop, :invalid_subscription}

  defp init_state(key, plc, db, offset, length, interval, point) do
    encoded_plc = URI.encode(to_string(plc), &URI.char_unreserved?/1)

    {:ok,
     %{
       key: key,
       plc: plc,
       db: db,
       offset: offset,
       length: length,
       interval: interval,
       point: point,
       topic: "plc/#{encoded_plc}/db/#{db}/#{offset}/#{length}/#{interval}",
       stream_id: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
       subscribers: %{},
       last: nil,
       last_error: nil,
       last_event: nil,
       sequence: 0,
       polling: false
     }}
  end

  @doc "登记并监控订阅者；首个订阅者到来时开始轮询。"
  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    if subscriber in Map.values(state.subscribers) do
      {:reply, {:ok, self()}, state}
    else
      if map_size(state.subscribers) == 0, do: send(self(), :poll)
      ref = Process.monitor(subscriber)
      if state.last_event != nil, do: send(subscriber, {:plc_event, state.last_event})
      {:reply, {:ok, self()}, %{state | subscribers: Map.put(state.subscribers, ref, subscriber)}}
    end
  end

  @doc "启动异步读取，避免阻塞处理新订阅和进程退出消息。"
  @impl true
  def handle_info(:poll, %{polling: false} = state) do
    parent = self()
    %{plc: plc, db: db, offset: offset, length: length} = state

    spawn(fn ->
      result =
        try do
          PlcService.Device.read(plc, db, offset, length)
        catch
          :exit, reason -> {:error, reason}
        end

      send(parent, {:poll_result, result})
    end)

    {:noreply, %{state | polling: true}}
  end

  # 已有读取在进行时忽略重复的轮询消息。
  def handle_info(:poll, state), do: {:noreply, state}

  # 只广播变化后的字节，错误则广播错误；随后安排下一次轮询。
  def handle_info({:poll_result, result}, state) do
    state = handle_result(result, state)
    Process.send_after(self(), :poll, state.interval)
    {:noreply, %{state | polling: false}}
  end

  # 移除已退出的订阅者；无人订阅时停止块进程。
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    subscribers = Map.delete(state.subscribers, ref)

    if map_size(subscribers) == 0 do
      {:stop, :normal, %{state | subscribers: subscribers}}
    else
      {:noreply, %{state | subscribers: subscribers}}
    end
  end

  defp handle_result({:ok, bytes}, state) do
    reason =
      cond do
        state.last_event == nil -> :initial
        state.last_error != nil -> :recovered
        bytes != state.last -> :change
        true -> nil
      end

    value_result =
      if state.point, do: PlcService.Point.decode(bytes, state.point), else: {:ok, bytes}

    case value_result do
      {:ok, value} ->
        state = %{state | last: bytes, last_error: nil}
        if reason == nil, do: state, else: publish(state, :data, value, reason)

      {:error, reason} ->
        handle_result({:error, reason}, state)
    end
  end

  defp handle_result({:error, reason}, state) do
    if state.last_event == nil or state.last_error != reason do
      state
      |> Map.put(:last_error, reason)
      |> publish(:error, reason, :read_failed)
    else
      state
    end
  end

  defp publish(state, type, value, reason) do
    event =
      PlcService.Event.new(%{
        type: type,
        topic: state.topic,
        device_id: state.plc,
        address: %{db: state.db, offset: state.offset, length: state.length},
        value: value,
        sequence: state.sequence + 1,
        quality: if(type == :data, do: :good, else: :bad),
        metadata: %{reason: reason, stream_id: state.stream_id}
      })

    Enum.each(state.subscribers, fn {_, subscriber} ->
      send(subscriber, {:plc_event, event})
    end)

    %{state | last_event: event, sequence: event.sequence}
  end
end
