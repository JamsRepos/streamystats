import Config

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: StreamystatServer.Finch

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

# Set Phoenix request logging to debug level
config :streamystat_server, StreamystatServerWeb.Endpoint, log: :debug

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.

config :streamystat_server, StreamystatServer.Repo,
  adapter: Postgrex,
  types: StreamystatServer.PostgrexTypes
