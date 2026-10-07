defmodule PlcService.PointTest do
  use ExUnit.Case, async: true

  test "decodes common Siemens point types" do
    assert PlcService.Point.decode(<<1>>, %{type: :bool, bit: 0}) == {:ok, true}
    assert PlcService.Point.decode(<<2>>, %{type: :bool, bit: 1}) == {:ok, true}
    assert PlcService.Point.decode(<<0xFF, 0xFE>>, %{type: :int16}) == {:ok, -2}
    assert PlcService.Point.decode(<<0x00, 0x2A>>, %{type: :uint16}) == {:ok, 42}
    assert PlcService.Point.decode(<<"OK", 0, 0>>, %{type: :string}) == {:ok, "OK"}
  end

  test "validates point configuration" do
    assert PlcService.Point.validate(%{db: 1, offset: 0, type: :bool, bit: 0}) == :ok
    assert PlcService.Point.validate(%{db: 1, offset: 0, type: :bool}) == {:error, :missing_bit}
    assert PlcService.Point.validate(%{db: 1, offset: 0, type: :bytes, size: 4}) == :ok

    assert PlcService.Point.validate(%{db: 1, offset: 0, type: :bytes}) ==
             {:error, :invalid_size}

    assert PlcService.Point.validate(%{db: 1, offset: 0, type: :string, size: 0}) ==
             {:error, :invalid_size}

    assert PlcService.Point.validate(%{db: 1, offset: 2_147_483_648, type: :uint16}) ==
             {:error, :invalid_point}

    assert PlcService.Point.validate(%{db: 1, offset: 2_147_483_647, type: :uint16}) ==
             {:error, :invalid_point}
  end
end
