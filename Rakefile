# frozen_string_literal: true

require "rspec/core/rake_task"

# Layers 1 and 2 (W29, Q18): every spec on MRI, no network, with the coverage
# floor. The end-to-end spec is in the run and skips itself unless asked.
RSpec::Core::RakeTask.new(:spec)

# Layer 3: the end-to-end spec alone, on a local icp-cli network. Needs
# E2E_BASE and E2E_PACKER (and E2E_ICP, ICP_CLI_NETWORK_LAUNCHER_PATH as
# needed); see spec/e2e/local_network_spec.rb. Run before each release.
desc "run the end-to-end spec on a local icp-cli network (needs E2E_BASE and E2E_PACKER)"
task :e2e do
  abort "set E2E_BASE and E2E_PACKER first (see spec/e2e/local_network_spec.rb)" unless ENV["E2E_BASE"] && ENV["E2E_PACKER"]
  ENV["E2E_ONLY"] = "1"
  sh "rspec spec/e2e"
end

task default: :spec
