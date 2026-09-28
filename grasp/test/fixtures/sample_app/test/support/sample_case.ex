defmodule SampleApp.SampleCase do
  @moduledoc "The case template the sample app's request tests use."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import SampleApp.SampleCase

      @endpoint SampleAppWeb.Endpoint
    end
  end

  setup do
    {:ok, conn: conn_for("sample-case")}
  end

  @doc "A test connection carrying `label` as its request id."
  @spec conn_for(String.t()) :: Plug.Conn.t()
  def conn_for(label) do
    Plug.Conn.put_req_header(Phoenix.ConnTest.build_conn(), "x-request-id", label)
  end
end
