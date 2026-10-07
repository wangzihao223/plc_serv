defmodule PlcService.Device do
  @moduledoc "管理一台 PLC 的连接会话，并通过 C Port 发送读取请求。"
  use GenServer
  import Bitwise

  @timeout 5_000
  @max_consecutive_timeouts 3

  @doc "启动设备进程，并按 PLC id 注册到应用注册表。"
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {PlcServer.Registry, {:device, Keyword.fetch!(opts, :id)}, opts}}
    )
  end

  @doc "检查读取参数，找到设备并等待读取结果。"
  def read(plc, db, offset, length) do
    with true <-
           is_integer(db) and db in 0..65_535 and is_integer(offset) and
             offset in 0..2_147_483_647 and
             is_integer(length) and length in 1..65_536 and
             offset <= 2_147_483_648 - length do
      case Registry.lookup(PlcServer.Registry, {:device, plc}) do
        [{pid, _}] -> GenServer.call(pid, {:read, db, offset, length}, :infinity)
        [] -> {:error, :unknown_plc}
      end
    else
      _ -> {:error, :invalid_read}
    end
  end

  @doc "向 PLC 的 DB 原始范围写入二进制数据。"
  def write(plc, db, offset, data) when is_binary(data) do
    with true <-
           is_integer(db) and db in 0..65_535 and is_integer(offset) and offset >= 0 and
             offset <= 2_147_483_647 and byte_size(data) in 1..65_536 and
             offset <= 2_147_483_648 - byte_size(data) do
      case Registry.lookup(PlcServer.Registry, {:device, plc}) do
        [{pid, _}] -> GenServer.call(pid, {:write, db, offset, data}, :infinity)
        [] -> {:error, :unknown_plc}
      end
    else
      _ -> {:error, :invalid_write}
    end
  end

  def write(_, _, _, _), do: {:error, :invalid_write}

  @doc "在设备进程中串行完成一个 DB 位的读取、修改和写入。"
  def write_bit(plc, db, offset, bit, value)
      when is_integer(db) and db in 0..65_535 and is_integer(offset) and
             offset in 0..2_147_483_647 and is_integer(bit) and bit in 0..7 and
             is_boolean(value) do
    case Registry.lookup(PlcServer.Registry, {:device, plc}) do
      [{pid, _}] -> GenServer.call(pid, {:write_bit, db, offset, bit, value}, :infinity)
      [] -> {:error, :unknown_plc}
    end
  end

  def write_bit(_, _, _, _, _), do: {:error, :invalid_write}

  @doc "控制模拟 PLC 的断线、重连或下一次请求超时。"
  def mock_control(plc, action) when action in [:disconnect, :reconnect, :timeout_next] do
    case Registry.lookup(PlcServer.Registry, {:device, plc}) do
      [{pid, _}] -> GenServer.call(pid, {:mock_control, action}, :infinity)
      [] -> {:error, :unknown_plc}
    end
  end

  def mock_control(_, _), do: {:error, :invalid_mock_action}

  @doc "返回 Port 状态及最近一次读写结果，不主动连接 PLC。"
  def status(plc) do
    case Registry.lookup(PlcServer.Registry, {:device, plc}) do
      [{pid, _}] -> GenServer.call(pid, :status)
      [] -> {:error, :unknown_plc}
    end
  end

  @doc "在主动移除或更新前回复所有等待中的请求。"
  def prepare_shutdown(pid, reason) do
    try do
      GenServer.call(pid, {:prepare_shutdown, reason})
    catch
      :exit, _ -> {:error, :device_unavailable}
    end
  end

  @doc "启动 C Port，并初始化请求编号和等待中的请求。"
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.get(opts, :port_path, Application.app_dir(:plc_server, "priv/plc_port"))

    args = [
      Keyword.fetch!(opts, :host),
      to_string(Keyword.fetch!(opts, :rack)),
      to_string(Keyword.fetch!(opts, :slot))
    ]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(path)},
        [:binary, {:packet, 4}, :exit_status, args: Enum.map(args, &String.to_charlist/1)]
      )

    {:ok,
     %{
       port: port,
       id: Keyword.fetch!(opts, :id),
       next_id: 1,
       pending: %{},
       bit_write: false,
       queued: :queue.new(),
       closing: nil,
       timeout: Keyword.get(opts, :timeout, @timeout),
       consecutive_timeouts: 0,
       last_io: :unknown,
       last_io_at: nil,
       max_consecutive_timeouts:
         Keyword.get(opts, :max_consecutive_timeouts, @max_consecutive_timeouts),
       mock: Keyword.fetch!(opts, :host) == "--mock"
     }}
  end

  @doc "编码并发送读取请求，同时保存原调用者以便异步回复。"
  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        device_id: state.id,
        port: if(Port.info(state.port), do: :running, else: :down),
        last_io: state.last_io,
        last_io_at: state.last_io_at
      }}, state}
  end

  def handle_call({:prepare_shutdown, reason}, _from, state) do
    error = {:error, reason}

    Enum.each(state.pending, fn {_, {from, timer, _}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, error)
    end)

    state.queued
    |> :queue.to_list()
    |> Enum.each(fn {_, from} -> GenServer.reply(from, error) end)

    {:reply, :ok,
     %{state | pending: %{}, queued: :queue.new(), bit_write: false, closing: reason}}
  end

  def handle_call(_request, _from, %{closing: reason} = state) when reason != nil do
    {:reply, {:error, reason}, state}
  end

  def handle_call(request, from, %{bit_write: true} = state) do
    {:noreply, %{state | queued: :queue.in({request, from}, state.queued)}}
  end

  def handle_call({:read, db, offset, length}, from, state) do
    id = state.next_id
    request = <<id::32, 1, db::16, offset::32, length::32>>
    true = Port.command(state.port, request)
    timer = Process.send_after(self(), {:timeout, id}, state.timeout)

    {:noreply,
     %{
       state
       | next_id: rem(id, 4_294_967_295) + 1,
         pending: Map.put(state.pending, id, {from, timer, {:read, length}})
     }}
  end

  def handle_call({:write_bit, db, offset, bit, value}, from, state) do
    id = state.next_id
    true = Port.command(state.port, <<id::32, 1, db::16, offset::32, 1::32>>)
    timer = Process.send_after(self(), {:timeout, id}, state.timeout)

    {:noreply,
     %{
       state
       | next_id: rem(id, 4_294_967_295) + 1,
         bit_write: true,
         pending: Map.put(state.pending, id, {from, timer, {:bit_read, db, offset, bit, value}})
     }}
  end

  @impl true
  def handle_call({:write, db, offset, data}, from, state) do
    id = state.next_id
    request = <<id::32, 2, db::16, offset::32, byte_size(data)::32, data::binary>>
    true = Port.command(state.port, request)
    timer = Process.send_after(self(), {:timeout, id}, state.timeout)

    {:noreply,
     %{
       state
       | next_id: rem(id, 4_294_967_295) + 1,
         pending: Map.put(state.pending, id, {from, timer, :write})
     }}
  end

  @impl true
  def handle_call({:mock_control, action}, from, %{mock: true} = state) do
    id = state.next_id
    command = %{disconnect: 1, reconnect: 2, timeout_next: 3}[action]
    true = Port.command(state.port, <<id::32, 3, command::16, 0::32, 1::32>>)
    timer = Process.send_after(self(), {:timeout, id}, state.timeout)

    {:noreply,
     %{
       state
       | next_id: rem(id, 4_294_967_295) + 1,
         pending: Map.put(state.pending, id, {from, timer, :control})
     }}
  end

  def handle_call({:mock_control, _}, _from, state), do: {:reply, {:error, :not_mock}, state}

  @doc "接收 C Port 响应，按请求编号回复原调用者。"
  @impl true
  def handle_info({port, {:data, <<id::32, status, payload::binary>>}}, %{port: port} = state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, timer, operation}, pending} ->
        Process.cancel_timer(timer)

        result =
          case {status, operation} do
            {0, {:read, length}} when byte_size(payload) == length -> {:ok, payload}
            {0, {:bit_read, _, _, _, _}} when byte_size(payload) == 1 -> {:ok, payload}
            {0, :write} when payload == <<>> -> {:ok, :written}
            {0, :bit_write} when payload == <<>> -> {:ok, :written}
            {0, :control} when payload == <<>> -> :ok
            {0, _} -> {:error, :invalid_response}
            {1, _} -> {:error, decode_error(payload)}
            _ -> {:error, :invalid_response}
          end

        state = %{state | pending: pending}

        state =
          if operation == :control do
            state
          else
            %{state | consecutive_timeouts: 0}
            |> record_io(result)
          end

        {:noreply, complete_request(state, from, operation, result)}
    end
  end

  def handle_info({:timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {{from, _, operation}, pending} ->
        state = %{state | pending: pending}
        state = if operation == :control, do: state, else: record_io(state, {:error, :timeout})

        if operation != :control and
             state.consecutive_timeouts + 1 >= state.max_consecutive_timeouts do
          GenServer.reply(from, {:error, :timeout})
          stop_device(state, {:port_timeout, state.max_consecutive_timeouts})
        else
          state =
            if operation == :control,
              do: state,
              else: %{state | consecutive_timeouts: state.consecutive_timeouts + 1}

          {:noreply, complete_request(state, from, operation, {:error, :timeout})}
        end
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    stop_device(state, {:port_exit, status})
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    stop_device(state, {:port_exit, reason})
  end

  defp stop_device(state, reason) do
    error = {:error, reason}

    Enum.each(state.pending, fn {_, {from, timer, _}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, error)
    end)

    state.queued
    |> :queue.to_list()
    |> Enum.each(fn {_, from} -> GenServer.reply(from, error) end)

    {:stop, reason, state}
  end

  defp complete_request(state, from, {:bit_read, db, offset, bit, value}, {:ok, <<byte>>}) do
    updated_byte =
      if value, do: bor(byte, 1 <<< bit), else: band(byte, bnot(1 <<< bit))

    id = state.next_id
    true = Port.command(state.port, <<id::32, 2, db::16, offset::32, 1::32, updated_byte>>)
    timer = Process.send_after(self(), {:timeout, id}, state.timeout)

    %{
      state
      | next_id: rem(id, 4_294_967_295) + 1,
        pending: Map.put(state.pending, id, {from, timer, :bit_write})
    }
  end

  defp complete_request(state, from, operation, result) do
    GenServer.reply(from, result)

    if operation == :bit_write or match?({:bit_read, _, _, _, _}, operation) do
      drain_queued(%{state | bit_write: false})
    else
      state
    end
  end

  defp drain_queued(%{bit_write: true} = state), do: state

  defp drain_queued(state) do
    case :queue.out(state.queued) do
      {{:value, {request, from}}, queued} ->
        case handle_call(request, from, %{state | queued: queued}) do
          {:noreply, next_state} ->
            drain_queued(next_state)

          {:reply, result, next_state} ->
            GenServer.reply(from, result)
            drain_queued(next_state)
        end

      {:empty, _} ->
        state
    end
  end

  defp decode_error(<<code::signed-32>>), do: {:snap7, code}
  defp decode_error(_), do: :invalid_response

  defp record_io(state, result) do
    %{
      state
      | last_io: if(match?({:ok, _}, result), do: :ok, else: result),
        last_io_at: System.system_time(:millisecond)
    }
  end
end
