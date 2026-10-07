Code.require_file("mix_tasks/compile.plc_port.ex", __DIR__)

defmodule PlcServer.MixProject do
  @moduledoc "Mix 项目配置和 OTP 应用入口。"
  use Mix.Project

  @doc "声明项目版本、Elixir 版本和 C Port 编译器。"
  def project do
    [
      app: :plc_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: [:plc_port] ++ Mix.compilers(),
      deps: [{:tortoise311, "~> 0.12.3"}, {:jason, "~> 1.4"}, {:bandit, "~> 1.12"}]
    ]
  end

  @doc "指定应用启动回调及日志依赖。"
  def application do
    [extra_applications: [:logger, :crypto], mod: {PlcServer.Application, []}]
  end
end
