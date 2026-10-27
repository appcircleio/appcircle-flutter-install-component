require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

$stdout.sync = true

DEFAULT_STORAGE_BASE_URL = 'https://storage.googleapis.com'.freeze
FLUTTER_REPO_URL = 'https://github.com/flutter/flutter.git'.freeze
CHANNELS = %w[stable beta].freeze
INSTALL_MARKER = '.ac_flutter_install.json'.freeze
GIT_PROBE_TIMEOUT_SECONDS = 30

def get_env_variable(key)
  value = ENV[key]
  value.nil? || value.strip.empty? ? nil : value.strip
end

def run_command(*command, allow_failure: false)
  puts "@@[command] #{command.join(' ')}"
  status = Open3.popen2e(*command) do |_stdin, output, wait_thr|
    output.each_line { |line| puts line }
    wait_thr.value
  end
  return true if status.success?

  message = "Command failed with exit code #{status.exitstatus}: #{command.join(' ')}"
  raise message unless allow_failure

  puts "Warning: #{message}"
  false
end

# Flutter publishes macOS archives for arm64 and x64, and Linux archives for x64 only.
# On macOS, hw.optional.arm64 reports Apple silicon even when Ruby runs under Rosetta.
def detect_platform
  os = `uname -s`.strip
  case os
  when 'Darwin'
    apple_silicon = `sysctl -n hw.optional.arm64 2>/dev/null`.strip == '1'
    { os: 'macos', arch: apple_silicon ? 'arm64' : 'x64' }
  when 'Linux'
    machine = `uname -m`.strip
    { os: 'linux', arch: %w[aarch64 arm64].include?(machine) ? 'arm64' : 'x64' }
  else
    abort "Unsupported operating system: #{os}"
  end
end

def releases_url(base_url)
  "#{base_url}/flutter_infra_release/releases"
end

def manifest_url(base_url, platform)
  "#{releases_url(base_url)}/releases_#{platform[:os]}.json"
end

def download(url, destination, allow_failure: false)
  run_command('curl', '--fail', '--silent', '--show-error', '--location',
              '--retry', '3', '--retry-delay', '5', '--connect-timeout', '30',
              '--output', destination, url, allow_failure: allow_failure)
end

def fetch_manifest(base_url, platform)
  Dir.mktmpdir('flutter-manifest') do |tmp|
    path = File.join(tmp, 'releases.json')
    return nil unless download(manifest_url(base_url, platform), path, allow_failure: true)

    JSON.parse(File.read(path))
  end
rescue JSON::ParserError => e
  puts "Warning: the Flutter release manifest is not valid JSON: #{e.message}"
  nil
end

def strip_v_prefix(version)
  version.to_s.sub(/\Av/, '')
end

# Releases older than 2.12 have no dart_sdk_arch field; they are x64 builds.
def release_arch(release)
  release['dart_sdk_arch'] || 'x64'
end

# The manifest lists the newest entry first, so `find` returns the latest re-release of a version.
def pick_for_platform(candidates, platform)
  exact = candidates.find { |release| release_arch(release) == platform[:arch] }
  return exact if exact
  return nil unless platform[:os] == 'macos' && platform[:arch] == 'arm64'

  fallback = candidates.find { |release| release_arch(release) == 'x64' }
  puts 'Warning: this version has no arm64 archive; installing the x64 archive, which runs under Rosetta.' if fallback
  fallback
end

def find_release(manifest, requested, platform)
  releases = manifest['releases'] || []
  candidates =
    if CHANNELS.include?(requested)
      current_hash = (manifest['current_release'] || {})[requested]
      releases.select { |release| release['hash'] == current_hash && release['channel'] == requested }
    else
      releases.select { |release| strip_v_prefix(release['version']) == strip_v_prefix(requested) }
    end
  pick_for_platform(candidates, platform)
end

def sdk_root
  File.join(Dir.home, 'flutter-sdk')
end

def flutter_executable(install_dir)
  File.join(install_dir, 'flutter', 'bin', 'flutter')
end

def read_marker(install_dir)
  marker = File.join(install_dir, INSTALL_MARKER)
  return nil unless File.file?(marker) && File.executable?(flutter_executable(install_dir))

  JSON.parse(File.read(marker))
rescue JSON::ParserError
  nil
end

def extract(archive, destination, platform)
  if archive.end_with?('.zip')
    # ditto is about four times faster than unzip for the macOS SDK archive.
    if platform[:os] == 'macos'
      run_command('ditto', '-x', '-k', archive, destination)
    else
      run_command('unzip', '-q', archive, '-d', destination)
    end
  else
    run_command('tar', '-xf', archive, '-C', destination)
  end
end

def install_release(release, base_url, install_dir, platform)
  url = "#{releases_url(base_url)}/#{release['archive']}"
  puts "Archive URL: #{url}"
  staging_dir = "#{install_dir}.partial-#{Process.pid}"
  Dir.mktmpdir('flutter-archive') do |tmp|
    archive = File.join(tmp, File.basename(release['archive']))
    download(url, archive)
    checksum = Digest::SHA256.file(archive).hexdigest
    unless checksum == release['sha256']
      abort "Checksum mismatch for #{File.basename(archive)}: expected #{release['sha256']}, got #{checksum}."
    end
    puts "Checksum verified (sha256 #{checksum})."

    FileUtils.rm_rf(staging_dir)
    FileUtils.mkdir_p(staging_dir)
    extract(archive, staging_dir, platform)
  end
  marker = {
    'version' => release['version'],
    'channel' => release['channel'],
    'arch' => release_arch(release),
    'archive' => release['archive'],
    'sha256' => release['sha256']
  }
  File.write(File.join(staging_dir, INSTALL_MARKER), JSON.pretty_generate(marker))
  FileUtils.rm_rf(install_dir)
  File.rename(staging_dir, install_dir)
ensure
  FileUtils.rm_rf(staging_dir) if staging_dir
end

def install_from_manifest(release, base_url, platform)
  puts "Resolved Flutter version: #{release['version']} (channel #{release['channel']}, #{release_arch(release)})"
  install_dir = File.join(sdk_root, release['version'])
  marker = read_marker(install_dir)
  if marker && marker['sha256'] == release['sha256']
    puts "Flutter #{release['version']} is already installed at #{install_dir}; skipping the download."
  else
    install_release(release, base_url, install_dir, platform)
    puts "Installed Flutter #{release['version']} to #{install_dir}."
  end
  File.join(install_dir, 'flutter')
end

# Without the manifest an explicit version can still use an SDK that a runner kept or Cache Pull restored.
def find_installed_without_manifest(requested)
  return nil if CHANNELS.include?(requested)

  [requested, strip_v_prefix(requested), "v#{strip_v_prefix(requested)}"].uniq.each do |name|
    install_dir = File.join(sdk_root, name)
    next unless read_marker(install_dir)

    puts "Warning: could not verify Flutter #{requested} against the release manifest; using the SDK at #{install_dir}."
    return File.join(install_dir, 'flutter')
  end
  nil
end

def git_reachable?
  pid = Process.spawn({ 'GIT_TERMINAL_PROMPT' => '0' }, 'git', 'ls-remote', '--exit-code', FLUTTER_REPO_URL, 'HEAD',
                      out: File::NULL, err: File::NULL)
  deadline = Time.now + GIT_PROBE_TIMEOUT_SECONDS
  loop do
    _, status = Process.waitpid2(pid, Process::WNOHANG)
    return status.success? if status

    if Time.now > deadline
      Process.kill('TERM', pid)
      Process.wait(pid)
      return false
    end
    sleep 1
  end
end

# A full clone, as before: the Flutter tool computes its version from the git tags.
def install_from_git(ref)
  install_dir = File.join(sdk_root, "git-#{ref.gsub(/[^0-9A-Za-z._-]/, '_')}")
  flutter_dir = File.join(install_dir, 'flutter')
  FileUtils.rm_rf(install_dir)
  FileUtils.mkdir_p(install_dir)
  if ref.match?(/\A\h{7,40}\z/)
    run_command('git', 'clone', FLUTTER_REPO_URL, flutter_dir)
    run_command('git', '-C', flutter_dir, 'checkout', ref)
  else
    run_command('git', 'clone', '-b', ref, FLUTTER_REPO_URL, flutter_dir)
  end
  flutter_dir
end

def install_sdk(requested, base_url, platform)
  manifest = fetch_manifest(base_url, platform)
  release = manifest && find_release(manifest, requested, platform)
  return install_from_manifest(release, base_url, platform) if release

  if manifest.nil?
    installed = find_installed_without_manifest(requested)
    return installed if installed
  elsif CHANNELS.include?(requested)
    abort "The release manifest has no #{platform[:os]} #{platform[:arch]} archive for the current #{requested} release."
  end

  puts "Flutter #{requested} has no release archive for #{platform[:os]} #{platform[:arch]}; " \
       "installing it with git from #{FLUTTER_REPO_URL}."
  unless git_reachable?
    abort "Flutter #{requested} is only available via git; use a released version." if manifest
    abort "Could not reach #{manifest_url(base_url, platform)} or #{FLUTTER_REPO_URL}. " \
          'Set FLUTTER_STORAGE_BASE_URL to a mirror of the Flutter storage, or restore the SDK with Cache Pull.'
  end
  install_from_git(requested)
end

# Every flutter command checks GitHub for a newer version first. Without internet access this waits
# about 75 seconds per command, so mark the check as done.
def write_version_check_stamp(flutter_dir)
  cache_dir = File.join(flutter_dir, 'bin', 'cache')
  FileUtils.mkdir_p(cache_dir)
  now = Time.now.utc.strftime('%Y-%m-%d %H:%M:%S.000')
  stamp = {
    'lastTimeVersionWasChecked' => now,
    'lastKnownRemoteVersion' => now,
    'lastTimeWarningWasPrinted' => now
  }
  File.write(File.join(cache_dir, 'flutter_version_check.stamp'), JSON.generate(stamp))
end

def main
  env_var_path = get_env_variable('AC_ENV_FILE_PATH') || abort('Missing environment variable path.')
  # AC_FLUTTER_VERSION (build configuration) overrides the step input.
  requested = get_env_variable('AC_FLUTTER_VERSION') || get_env_variable('AC_SELECTED_FLUTTER_VERSION') || 'stable'
  base_url = (get_env_variable('FLUTTER_STORAGE_BASE_URL') || DEFAULT_STORAGE_BASE_URL).chomp('/')
  platform = detect_platform

  puts "Selected Flutter version: #{requested}"
  puts "Platform: #{platform[:os]} #{platform[:arch]}"
  puts "Flutter storage base URL: #{base_url}"

  flutter_dir = install_sdk(requested, base_url, platform)
  write_version_check_stamp(flutter_dir)

  ENV['PATH'] = "#{File.join(flutter_dir, 'bin')}:#{ENV['PATH']}"
  puts "PATH=#{ENV['PATH']}"
  run_command('flutter', 'config', '--no-analytics', allow_failure: true)
  run_command('flutter', '--no-version-check', '--version')
  # flutter doctor checks hosts on the internet; skip it when the build uses a mirror.
  if base_url == DEFAULT_STORAGE_BASE_URL
    run_command('flutter', 'doctor', allow_failure: true)
  else
    puts 'Skipping flutter doctor because FLUTTER_STORAGE_BASE_URL points to a mirror.'
  end

  File.open(env_var_path, 'a') { |f| f.puts "PATH=#{ENV['PATH']}" }
end

main if __FILE__ == $PROGRAM_NAME
