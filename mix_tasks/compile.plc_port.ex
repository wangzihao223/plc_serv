defmodule Mix.Tasks.Compile.PlcPort do
  @moduledoc "在 Mix 编译时用系统 C 编译器构建 Port 可执行文件。"
  use Mix.Task.Compiler

  @doc "编译 C 源码并将编译错误交给 Mix 显示。"
  @impl true
  def run(_args) do
    File.mkdir_p!("priv")
    compiler = System.get_env("CC", "cc")
    args = ["-std=c11", "-O2", "-Wall", "-Wextra", "-o", "priv/plc_port", "c_src/plc_port.c"]
    args = if match?({:unix, _}, :os.type()), do: args ++ ["-ldl"], else: args

    case System.cmd(compiler, args, stderr_to_stdout: true) do
      {_, 0} ->
        {:ok, []}

      {output, _} ->
        {:error,
         [
           %Mix.Task.Compiler.Diagnostic{
             file: "c_src/plc_port.c",
             position: nil,
             compiler_name: "cc",
             message: output,
             severity: :error
           }
         ]}
    end
  end
end
