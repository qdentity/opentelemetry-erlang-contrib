defmodule OpentelemetryOban do
  @moduledoc """
  OpentelemetryOban uses [telemetry](https://hexdocs.pm/telemetry/) handlers to
  create `OpenTelemetry` spans from Oban events.

  Supported events include job start/stop and also when an exception is raised.

  ## Usage

  In your application start:

      def start(_type, _args) do
        OpentelemetryOban.setup()

        # ...
      end
  """

  alias Ecto.Changeset
  alias OpenTelemetry.Span

  require OpenTelemetry.Tracer

  @tracer_id :opentelemetry_oban

  @doc """
  Initializes and configures telemetry handlers.

  ## Sampling

  By default only jobs are sampled. If you wish to sample plugins as well then use:

      OpentelemetryOban.setup(trace: [:jobs, :plugins])

  It is also possible to provide your own sampler:

      OpentelemetryOban.setup(
        trace: [
          jobs: :otel_sampler.new(:always_on),
          plugins: :otel_sampler.new(:always_on)
        ]
      )
  """
  @spec setup() :: :ok
  def setup(opts \\ []) do
    {:ok, otel_tracer_vsn} = :application.get_key(@tracer_id, :vsn)
    OpenTelemetry.register_tracer(@tracer_id, otel_tracer_vsn)

    always_on = :otel_sampler.new(:always_on)
    always_off = :otel_sampler.new(:always_off)

    OpentelemetryOban.JobHandler.attach(handler_opts(:jobs, opts, always_on))
    OpentelemetryOban.PluginHandler.attach(handler_opts(:plugins, opts, always_off))

    :ok
  end

  def insert(name \\ Oban, %Changeset{} = changeset) do
    attributes = attributes_before_insert(changeset)
    worker = Changeset.get_field(changeset, :worker, "unknown")

    OpenTelemetry.Tracer.with_span "#{worker} send", attributes: attributes, kind: :producer do
      changeset = add_tracing_information_to_meta(changeset)

      case Oban.insert(name, changeset) do
        {:ok, job} ->
          OpenTelemetry.Tracer.set_attributes(attributes_after_insert(job))
          {:ok, job}

        other ->
          other
      end
    end
  end

  def insert(name \\ Oban, multi, multi_name, changeset_or_fun) do
    Oban.insert(name, multi, multi_name, changeset_or_fun)
  end

  def insert!(name \\ Oban, %Changeset{} = changeset) do
    attributes = attributes_before_insert(changeset)
    worker = Changeset.get_field(changeset, :worker, "unknown")

    OpenTelemetry.Tracer.with_span "#{worker} send", attributes: attributes, kind: :producer do
      changeset = add_tracing_information_to_meta(changeset)

      try do
        job = Oban.insert!(name, changeset)
        OpenTelemetry.Tracer.set_attributes(attributes_after_insert(job))
        job
      rescue
        exception ->
          ctx = OpenTelemetry.Tracer.current_span_ctx()
          Span.record_exception(ctx, exception, __STACKTRACE__)
          Span.set_status(ctx, OpenTelemetry.status(:error, ""))
          reraise exception, __STACKTRACE__
      end
    end
  end

  def insert_all(name \\ Oban, changesets_or_wrapper)

  def insert_all(name, %{changesets: changesets}) when is_list(changesets) do
    insert_all(name, changesets)
  end

  def insert_all(name, changesets) when is_list(changesets) do
    # changesets in insert_all can include different workers and different
    # queues. This means we cannot provide much information here, but we can
    # still record the insert and propagate the context information.
    OpenTelemetry.Tracer.with_span "Oban bulk insert", kind: :producer do
      changesets = Enum.map(changesets, &add_tracing_information_to_meta/1)
      Oban.insert_all(name, changesets)
    end
  end

  def insert_all(name \\ __MODULE__, multi, multi_name, changesets_or_wrapper) do
    Oban.insert_all(name, multi, multi_name, changesets_or_wrapper)
  end

  defp add_tracing_information_to_meta(changeset) do
    meta = Changeset.get_field(changeset, :meta, %{})

    new_meta =
      []
      |> :otel_propagator_text_map.inject()
      |> Enum.into(meta)

    Changeset.change(changeset, %{meta: new_meta})
  end

  defp attributes_before_insert(changeset) do
    queue = Changeset.get_field(changeset, :queue, "unknown")
    worker = Changeset.get_field(changeset, :worker, "unknown")

    [
      "messaging.system": "oban",
      "messaging.destination": queue,
      "messaging.destination_kind": "queue",
      "messaging.oban.worker": worker
    ]
  end

  defp attributes_after_insert(job) do
    [
      "messaging.oban.job_id": job.id,
      "messaging.oban.priority": job.priority,
      "messaging.oban.max_attempts": job.max_attempts
    ]
  end

  defp handler_opts(name, opts, default_sampler) do
    trace = Keyword.get(opts, :trace, [])

    sampler =
      if Enum.member?(trace, name) do
        # If just the handler name is specified then use always on sampler
        :otel_sampler.new(:always_on)
      else
        # Use provided sampler or default to the default sampler
        Keyword.get(trace, name, default_sampler)
      end

    [sampler: sampler]
  end
end
