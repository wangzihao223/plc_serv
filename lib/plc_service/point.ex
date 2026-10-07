defmodule PlcService.Point do
  @moduledoc "S7 点位配置和原始字节解码器。"
  import Bitwise

  @types [:bool, :int16, :uint16, :int32, :uint32, :float32, :string, :bytes]

  @doc "根据点位配置计算需要读取的字节数。"
  def byte_length(%{type: :bool}), do: 1
  def byte_length(%{type: type}) when type in [:int16, :uint16], do: 2
  def byte_length(%{type: type}) when type in [:int32, :uint32, :float32], do: 4

  def byte_length(%{type: type, size: size})
      when type in [:string, :bytes] and is_integer(size) and size > 0, do: size

  @doc "按 Siemens S7 默认大端序把值编码为 PLC 字节。"
  def encode(value, %{type: :bool, bit: bit}) when is_boolean(value) and bit in 0..7 do
    {:ok, <<if(value, do: 1 <<< bit, else: 0)>>}
  end

  def encode(value, %{type: :int16}) when is_integer(value) and value in -32_768..32_767,
    do: {:ok, <<value::signed-big-16>>}

  def encode(value, %{type: :uint16}) when is_integer(value) and value in 0..65_535,
    do: {:ok, <<value::unsigned-big-16>>}

  def encode(value, %{type: :int32})
      when is_integer(value) and value in -2_147_483_648..2_147_483_647,
      do: {:ok, <<value::signed-big-32>>}

  def encode(value, %{type: :uint32}) when is_integer(value) and value in 0..4_294_967_295,
    do: {:ok, <<value::unsigned-big-32>>}

  def encode(value, %{type: :float32}) when is_float(value), do: {:ok, <<value::float-big-32>>}

  def encode(value, %{type: :bytes, size: size})
      when is_binary(value) and byte_size(value) == size, do: {:ok, value}

  def encode(value, %{type: :string, size: size})
      when is_binary(value) and byte_size(value) <= size,
      do: {:ok, value <> :binary.copy(<<0>>, size - byte_size(value))}

  def encode(_, _), do: {:error, :invalid_value}

  @doc "按 Siemens S7 默认大端序把字节解码为配置指定的值。"
  def decode(bytes, %{type: :bool, bit: bit}) when is_binary(bytes) and bit in 0..7 do
    <<byte, _::binary>> = bytes
    {:ok, band(byte, 1 <<< bit) != 0}
  end

  def decode(<<value::signed-big-16>>, %{type: :int16}), do: {:ok, value}
  def decode(<<value::unsigned-big-16>>, %{type: :uint16}), do: {:ok, value}
  def decode(<<value::signed-big-32>>, %{type: :int32}), do: {:ok, value}
  def decode(<<value::unsigned-big-32>>, %{type: :uint32}), do: {:ok, value}
  def decode(<<value::float-big-32>>, %{type: :float32}), do: {:ok, value}

  def decode(bytes, %{type: :string}) when is_binary(bytes),
    do: {:ok, bytes |> :binary.split(<<0>>, [:global]) |> hd() |> to_string()}

  def decode(bytes, %{type: :bytes}) when is_binary(bytes), do: {:ok, bytes}
  def decode(_, _), do: {:error, :invalid_point}

  @doc "验证点位配置。"
  def validate(%{db: db, offset: offset, type: type} = config)
      when is_integer(db) and db in 0..65_535 and is_integer(offset) and
             offset in 0..2_147_483_647 and
             type in @types do
    cond do
      type == :bool and is_integer(config[:bit]) and config[:bit] in 0..7 ->
        :ok

      type == :bool ->
        {:error, :missing_bit}

      type in [:string, :bytes] and is_integer(config[:size]) and
        config[:size] in 1..65_536 and offset <= 2_147_483_648 - config[:size] ->
        :ok

      type in [:string, :bytes] and
          (not is_integer(config[:size]) or
             config[:size] not in 1..65_536) ->
        {:error, :invalid_size}

      offset <= 2_147_483_648 - byte_length(config) ->
        :ok

      true ->
        {:error, :invalid_point}
    end
  end

  def validate(_), do: {:error, :invalid_point}
end
