defmodule OpentelemetryFinch do
  require OpenTelemetry.Tracer

  @tracer_id :opentelemetry_finch

  def setup(opts \\ []) do
    :telemetry.attach_many(
      __MODULE__,
      [
        [:finch, :request, :start],
        [:finch, :connect, :stop],
        [:finch, :request, :stop],
        [:finch, :send, :stop],
        [:finch, :recv, :stop],
        [:finch, :recv, :exception],
        [:finch, :request, :exception]
      ],
      &__MODULE__.handle_event/4,
      opts
    )
  end

  def handle_event(
        [:finch, :request, :start],
        _measurements,
        %{request: %Finch.Request{} = request} = metadata,
        _config
      ) do
    attributes = %{
      "http.method": request.method,
      "http.url": url(request),
      "http.target": request.path,
      "http.host": request.host,
      "http.scheme": Atom.to_string(request.scheme),
      "net.peer.port": request.port
    }

    OpentelemetryTelemetry.start_telemetry_span(
      @tracer_id,
      "HTTP #{request.method}",
      metadata,
      %{kind: :client, attributes: attributes}
    )
  end

  def handle_event(
        [:finch, event_kind, :stop],
        _measurements,
        metadata,
        _config
      )
      when event_kind in [:request, :connect, :send, :recv] do
    http_status = Map.get(metadata, :status)

    if http_status do
      OpenTelemetry.Tracer.set_attribute(:"http.status_code", http_status)

      if http_status >= 400 do
        OpenTelemetry.status(:error)
        |> OpenTelemetry.Tracer.set_status()
      end
    end

    if error = Map.get(metadata, :error) do
      OpenTelemetry.status(:error, format_error(error))
      |> OpenTelemetry.Tracer.set_status()
    end

    if event_kind == :request do
      end_span(metadata)
    end
  end

  def handle_event(
        [:finch, step, :exception],
        _measurements,
        metadata,
        _config
      )
      when step in [:recv, :request] do
    span_status =
      if reason = Map.get(metadata, :reason) do
        OpenTelemetry.status(:error, format_error(reason))
      else
        OpenTelemetry.status(:error)
      end

    OpenTelemetry.Tracer.set_status(span_status)

    if step == :request do
      end_span(metadata)
    end
  end

  defp end_span(metadata) do
    OpentelemetryTelemetry.end_telemetry_span(@tracer_id, metadata)
  end

  defp url(%Finch.Request{} = request) do
    %URI{
      scheme: Atom.to_string(request.scheme),
      host: request.host,
      port: request.port,
      path: request.path,
      query: request.query
    }
    |> URI.to_string()
  end

  defp format_error(%{reason: %{__exception__: true} = reason}) do
    format_error(reason)
  end

  defp format_error(%{__exception__: true} = exception) do
    Exception.message(exception)
  end

  defp format_error(error), do: inspect(error)
end
