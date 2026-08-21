import Config

# Renders the x-amz-request-id that FakeS3.RequestId attaches to each request,
# so a response header can be traced to the lines logged while serving it.
# Without listing it here, Logger.metadata/1 sets the value but the default
# formatter drops it.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]
