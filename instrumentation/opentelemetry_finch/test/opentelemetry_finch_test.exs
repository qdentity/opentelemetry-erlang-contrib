defmodule OpentelemetryFinchTest do
  use ExUnit.Case

  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  setup do
    :application.stop(:opentelemetry)
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)

    :application.set_env(:opentelemetry, :processors, [
      {:otel_batch_processor, %{scheduled_delay_ms: 1}}
    ])

    :application.start(:opentelemetry)

    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    bypass = Bypass.open()

    start_supervised!({Finch, name: TestClient})

    OpentelemetryFinch.setup()
    {:ok, bypass: bypass}
  end

  test "records basic attributes", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/foo", fn conn ->
      Plug.Conn.resp(conn, 201, "Hello World")
    end)

    path = "/foo?q0=a&q1=b"

    Finch.build(:get, "http://localhost:#{bypass.port}#{path}")
    |> Finch.request(TestClient)

    assert_receive {:span, span(name: "HTTP GET", attributes: attributes)}

    assert %{
             "http.method": "GET",
             "http.url": url,
             "http.target": "/foo",
             "http.host": "localhost",
             "http.scheme": "http",
             "http.status_code": 201,
             "net.peer.port": port
           } = :otel_attributes.map(attributes)

    assert url == "http://localhost:#{bypass.port}#{path}"
    assert port == bypass.port
  end

  test "http >= 400 is an error", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/foo", fn conn ->
      Plug.Conn.resp(conn, 400, "Hello World")
    end)

    Finch.build(:get, "http://localhost:#{bypass.port}/foo")
    |> Finch.request(TestClient)

    assert_receive {:span, span(name: "HTTP GET", status: {:status, :error, ""})}
  end

  test "exception in connect step" do
    Finch.build(:get, "http://dasdladklaskdlaslkdas.com")
    |> Finch.request(TestClient)

    assert_receive {:span,
                    span(name: "HTTP GET", status: {:status, :error, "non-existing domain"})}
  end

  test "exception in receive step", %{bypass: bypass} do
    Bypass.expect(bypass, "GET", "/foo", fn conn ->
      :timer.sleep(10)
      Plug.Conn.resp(conn, 200, "OK")
    end)

    Finch.build(:get, "http://localhost:#{bypass.port}/foo")
    |> Finch.request(TestClient, receive_timeout: 1)

    assert_receive {:span, span(name: "HTTP GET", status: {:status, :error, "timeout"})}

    Bypass.down(bypass)
  end
end
