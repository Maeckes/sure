# frozen_string_literal: true

Rails.application.configure do
  config.x.fints.product_id = ENV["FINTS_PRODUCT_ID"]
  config.x.fints.python_executable = ENV.fetch("FINTS_PYTHON", "python3")
  config.x.fints.worker_path = ENV.fetch("FINTS_WORKER_PATH", Rails.root.join("services/fints_worker/worker.py").to_s)
  config.x.fints.worker_timeout = Integer(ENV.fetch("FINTS_WORKER_TIMEOUT", 30))
  config.x.fints.output_limit = Integer(ENV.fetch("FINTS_WORKER_OUTPUT_LIMIT", 2.megabytes))
  config.x.fints.initial_history_days = 90
  config.x.fints.sync_lookback_days = 7
end
