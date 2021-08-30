defmodule OpentelemetryOban.PluginHandlerTest do
  use DataCase

  require OpenTelemetry.Tracer
  require OpenTelemetry.Span
  require Record

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry/include/otel_span.hrl") do
    Record.defrecord(name, spec)
  end

  for {name, spec} <- Record.extract_all(from_lib: "opentelemetry_api/include/opentelemetry.hrl") do
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

    TestHelpers.remove_oban_handlers()
    OpentelemetryOban.setup(trace: [:jobs, :plugins])

    :ok
  end

  test "records span on plugin execution" do
    :telemetry.execute(
      [:oban, :plugin, :start],
      %{system_time: System.system_time()},
      %{plugin: Elixir.Oban.Plugins.Stager}
    )

    :telemetry.execute(
      [:oban, :plugin, :stop],
      %{duration: 444},
      %{plugin: Elixir.Oban.Plugins.Stager}
    )

    assert_receive {:span, span(name: "Elixir.Oban.Plugins.Stager process")}
  end

  test "records span on plugin error" do
    :telemetry.execute(
      [:oban, :plugin, :start],
      %{system_time: System.system_time()},
      %{plugin: Elixir.Oban.Plugins.Stager}
    )

    :telemetry.execute(
      [:oban, :plugin, :exception],
      %{duration: 444},
      %{
        plugin: Elixir.Oban.Plugins.Stager,
        kind: :error,
        stacktrace: [
          {Some, :error, [], []}
        ],
        error: %UndefinedFunctionError{
          arity: 0,
          function: :error,
          message: nil,
          module: Some,
          reason: nil
        }
      }
    )

    expected_status = OpenTelemetry.status(:error, "")

    assert_receive {:span,
                    span(
                      name: "Elixir.Oban.Plugins.Stager process",
                      events: [
                        event(
                          name: "exception",
                          attributes: [
                            {"exception.type", "Elixir.UndefinedFunctionError"},
                            {"exception.message",
                             "function Some.error/0 is undefined (module Some is not available)"},
                            {"exception.stacktrace", _stacktrace}
                          ]
                        )
                      ],
                      status: ^expected_status
                    )}
  end
end
