# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'

MAIN_RB = File.expand_path('../main.rb', __dir__)
RUBY_BIN = RbConfig.ruby

# ─── Subprocess coverage ──────────────────────────────────────────────────────
# Everything under `if __FILE__ == $PROGRAM_NAME` only runs when main.rb is
# executed as a script, which the ENV and installation-flow tests do in a
# subprocess. This boot file is pushed into those subprocesses through RUBYOPT
# so their coverage is measured too, and merged into the report at the end.
CHILD_COVERAGE_DIR     = Dir.mktmpdir('flutter_install_child_cov')
CHILD_COVERAGE_RESULTS = File.join(CHILD_COVERAGE_DIR, 'results')
CHILD_COVERAGE_BOOT    = File.join(CHILD_COVERAGE_DIR, 'coverage_boot.rb')
FileUtils.mkdir_p(CHILD_COVERAGE_RESULTS)
File.write(CHILD_COVERAGE_BOOT, <<~'BOOT')
  require 'coverage'
  Coverage.start
  at_exit do
    dir = ENV['AC_TEST_COVERAGE_RESULTS']
    unless dir.nil? || dir.empty?
      File.binwrite(
        File.join(dir, "cov-#{Process.pid}-#{rand(1 << 32)}.dump"),
        Marshal.dump(Coverage.result)
      )
    end
  end
BOOT

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m", # bold blue
    "\e[35;1m", # bold magenta
    "\e[36;1m", # bold cyan
    "\e[33;1m"  # bold yellow
  ].freeze

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    total   = notification.examples.size
    passed  = @counts[:passed]
    failed  = @counts[:failed]
    pending = @counts[:pending]
    sec     = format('%.3fs', notification.duration)

    parts = ["\e[32m#{passed} passed\e[0m"]
    parts << "\e[31m#{failed} failed\e[0m"   if failed > 0
    parts << "\e[33m#{pending} pending\e[0m" if pending > 0

    overall = failed.zero? ? "\e[32;1m✔  All #{total} tests passed\e[0m" : "\e[31;1m✖  #{failed} of #{total} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Writes a stub `git` executable so the subprocess tests never clone the real
# Flutter SDK. It records its arguments and cwd, then — like a real
# `git clone` — materialises `flutter/bin/flutter` in the working directory by
# copying the stub interpreter from AC_TEST_FLUTTER_STUB_SRC. That copy is the
# only `flutter` binary anywhere in the child's PATH, so `flutter doctor` can
# only be resolved through the `flutter/bin/` entry main.rb appends to PATH.
def build_fake_bin(dir)
  FileUtils.mkdir_p(dir)

  flutter_stub_src = File.join(dir, 'flutter-stub-src')
  File.write(flutter_stub_src, <<~'SH')
    #!/bin/sh
    printf '%s\n' "$*" >> "$AC_TEST_FLUTTER_ARGS_FILE"
    printf '%s\n' "$0" >> "$AC_TEST_FLUTTER_PATH_FILE"
    if [ -n "$AC_TEST_FLUTTER_STDERR" ]; then
      printf '%s\n' "$AC_TEST_FLUTTER_STDERR" >&2
    fi
    exit "${AC_TEST_FLUTTER_EXIT:-0}"
  SH
  FileUtils.chmod(0o755, flutter_stub_src)

  git = File.join(dir, 'git')
  File.write(git, <<~'SH')
    #!/bin/sh
    printf '%s\n' "$*" >> "$AC_TEST_GIT_ARGS_FILE"
    pwd >> "$AC_TEST_GIT_CWD_FILE"
    if [ -n "$AC_TEST_GIT_STDERR" ]; then
      printf '%s\n' "$AC_TEST_GIT_STDERR" >&2
    fi
    if [ "${AC_TEST_GIT_EXIT:-0}" -ne 0 ]; then
      exit "$AC_TEST_GIT_EXIT"
    fi
    if [ "${AC_TEST_GIT_SKIP_SDK:-0}" -eq 0 ]; then
      mkdir -p flutter/bin
      cp "$AC_TEST_FLUTTER_STUB_SRC" flutter/bin/flutter
      chmod 755 flutter/bin/flutter
    fi
    exit 0
  SH
  FileUtils.chmod(0o755, git)

  dir
end

# Runs main.rb in a subprocess. Keys left at nil are unset in the child, so a
# "missing variable" case never inherits a value from the test runner.
def run_main(env = {}, chdir: nil, path: nil)
  spawn_env = {
    'AC_ENV_FILE_PATH'            => nil,
    'AC_SELECTED_FLUTTER_VERSION' => nil,
    'AC_FLUTTER_VERSION'          => nil
  }.merge(env)
  spawn_env['PATH'] = path if path
  spawn_env['AC_TEST_COVERAGE_RESULTS'] = CHILD_COVERAGE_RESULTS
  spawn_env['RUBYOPT'] = [ENV['RUBYOPT'], "-r#{CHILD_COVERAGE_BOOT}"].compact.join(' ').strip

  options = {}
  options[:chdir] = chdir if chdir
  Open3.capture3(spawn_env, RUBY_BIN, MAIN_RB, **options)
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'Required libraries' do
  %w[open3 yaml].each do |lib|
    it "loads '#{lib}'" do
      expect { require lib }.not_to raise_error
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    had_key = ENV.key?('_AC_TEST_VAR')
    old     = ENV['_AC_TEST_VAR']
    example.run
    had_key ? ENV['_AC_TEST_VAR'] = old : ENV.delete('_AC_TEST_VAR')
  end

  it 'returns the value when the key is set' do
    ENV['_AC_TEST_VAR'] = '3.19.0'
    expect(get_env_variable('_AC_TEST_VAR')).to eq('3.19.0')
  end

  it 'keeps a whitespace-only value, which is not an empty string' do
    ENV['_AC_TEST_VAR'] = ' '
    expect(get_env_variable('_AC_TEST_VAR')).to eq(' ')
  end

  it 'returns nil when the key is missing' do
    ENV.delete('_AC_TEST_VAR')
    expect(get_env_variable('_AC_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is an empty string' do
    ENV['_AC_TEST_VAR'] = ''
    expect(get_env_variable('_AC_TEST_VAR')).to be_nil
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_version' do
  it 'prefers the config version over the component version' do
    expect(get_version('stable', '3.19.0')).to eq('3.19.0')
  end

  it 'falls back to the component version when the config version is nil' do
    expect(get_version('stable', nil)).to eq('stable')
  end

  it 'returns the config version even when no component version was resolved' do
    expect(get_version(nil, '3.19.0')).to eq('3.19.0')
  end

  it 'returns nil when neither version is given' do
    expect(get_version(nil, nil)).to be_nil
  end

  # The nil check is on the config version only, so an empty string wins over
  # the component version. In the step itself this is unreachable, because
  # get_env_variable already turns an empty AC_FLUTTER_VERSION into nil.
  it 'treats an empty config version as a value, not as unset' do
    expect(get_version('stable', '')).to eq('')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  before { allow($stdout).to receive(:puts) }

  it 'returns without raising when the command succeeds' do
    expect { run_command('true') }.not_to raise_error
  end

  it 'echoes the command it is about to run' do
    run_command('true')
    expect($stdout).to have_received(:puts).with('@@[command] true')
  end

  it 'streams the stdout lines of the command' do
    run_command('echo line-one')
    expect($stdout).to have_received(:puts).with("line-one\n")
  end

  it 'raises with the stderr of the command when it exits non-zero' do
    expect { run_command('sh -c "echo boom >&2; exit 1"') }
      .to raise_error(RuntimeError, /boom/)
  end

  it 'prints the stderr before raising' do
    expect { run_command('sh -c "echo boom >&2; exit 1"') }.to raise_error(RuntimeError)
    expect($stdout).to have_received(:puts).with("boom\n")
  end

  it 'still raises when a failing command writes nothing to stderr' do
    expect { run_command('sh -c "exit 7"') }.to raise_error(RuntimeError)
  end

  it 'raises Errno::ENOENT when the command cannot be executed at all' do
    expect { run_command('ac_test_command_that_does_not_exist') }
      .to raise_error(Errno::ENOENT)
  end

  it 'raises Errno::ENOENT when the command is an empty string' do
    expect { run_command('') }.to raise_error(Errno::ENOENT)
  end

  it 'raises TypeError when the command is nil' do
    expect { run_command(nil) }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation' do
  let(:workdir) { Dir.mktmpdir('flutter_install_env') }
  after { FileUtils.rm_rf(workdir) }

  # The abort happens before anything is cloned, so these cases need no stubs.
  context 'AC_ENV_FILE_PATH' do
    it 'aborts when the variable is missing' do
      _out, err, status = run_main({}, chdir: workdir)
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing environment variable path.')
    end

    it 'aborts when the variable is an empty string' do
      _out, err, status = run_main({ 'AC_ENV_FILE_PATH' => '' }, chdir: workdir)
      expect(status.exitstatus).to eq(1)
      expect(err).to include('Missing environment variable path.')
    end

    it 'does not run git when the variable is missing' do
      bindir    = File.join(workdir, 'fakebin')
      args_file = File.join(workdir, 'git_args.txt')
      build_fake_bin(bindir)
      FileUtils.touch(args_file)

      _out, _err, status = run_main(
        { 'AC_TEST_GIT_ARGS_FILE' => args_file },
        chdir: workdir,
        path: "#{bindir}:/usr/bin:/bin"
      )

      expect(status.exitstatus).to eq(1)
      expect(File.read(args_file)).to be_empty
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Flutter installation flow (stubbed toolchain)' do
  let(:workdir)          { Dir.mktmpdir('flutter_install_run') }
  let(:bindir)           { File.join(workdir, 'fakebin') }
  let(:env_file)         { File.join(workdir, 'ac_env_file') }
  let(:git_args_file)    { File.join(workdir, 'git_args.txt') }
  let(:git_cwd_file)     { File.join(workdir, 'git_cwd.txt') }
  let(:flutter_args_file) { File.join(workdir, 'flutter_args.txt') }
  let(:flutter_path_file) { File.join(workdir, 'flutter_path.txt') }
  let(:repo_url)         { 'https://github.com/flutter/flutter.git' }
  # main.rb appends "#{Dir.pwd}/flutter/bin/" to PATH, and the cwd the kernel
  # reports for the child is the resolved path (on macOS /var is a symlink to
  # /private/var), so the expected PATH is built from the realpath.
  let(:sdk_bin_path)     { File.join(File.realpath(workdir), 'flutter/bin/') }
  let(:expected_path)    { "#{bindir}:/usr/bin:/bin:#{sdk_bin_path}" }

  before do
    build_fake_bin(bindir)
    [env_file, git_args_file, git_cwd_file, flutter_args_file, flutter_path_file]
      .each { |file| FileUtils.touch(file) }
  end

  after { FileUtils.rm_rf(workdir) }

  # Runs the step against the stub toolchain inside the temp working directory.
  def invoke(env = {})
    run_main(
      {
        'AC_ENV_FILE_PATH'           => env_file,
        'AC_TEST_GIT_ARGS_FILE'      => git_args_file,
        'AC_TEST_GIT_CWD_FILE'       => git_cwd_file,
        'AC_TEST_FLUTTER_ARGS_FILE'  => flutter_args_file,
        'AC_TEST_FLUTTER_PATH_FILE'  => flutter_path_file,
        'AC_TEST_FLUTTER_STUB_SRC'   => File.join(bindir, 'flutter-stub-src')
      }.merge(env),
      chdir: workdir,
      path: "#{bindir}:/usr/bin:/bin"
    )
  end

  def git_args
    File.read(git_args_file).strip
  end

  def flutter_args
    File.read(flutter_args_file).strip
  end

  context 'happy path' do
    it 'exits 0' do
      _out, _err, status = invoke
      expect(status.exitstatus).to eq(0)
    end

    it 'clones the Flutter SDK repository at the resolved version' do
      invoke
      expect(git_args).to eq("clone -b stable #{repo_url}")
    end

    it 'clones into the working directory of the step' do
      invoke
      expect(File.read(git_cwd_file).strip).to eq(File.realpath(workdir))
    end

    it 'runs flutter doctor after the clone' do
      invoke
      expect(flutter_args).to eq('doctor')
    end

    it 'runs the flutter binary from the cloned SDK' do
      invoke
      expect(File.read(flutter_path_file).strip).to eq("#{sdk_bin_path}flutter")
    end

    it 'reports the selected version on stdout' do
      out, _err, _status = invoke
      expect(out).to include('Selected flutter version is stable')
    end

    it 'echoes both commands it runs' do
      out, _err, _status = invoke
      expect(out).to include("@@[command] git clone -b stable #{repo_url}")
      expect(out).to include('@@[command] flutter doctor')
    end
  end

  context 'version resolution' do
    it 'defaults to stable when neither version variable is set' do
      invoke
      expect(git_args).to eq("clone -b stable #{repo_url}")
    end

    it 'defaults to stable when AC_SELECTED_FLUTTER_VERSION is an empty string' do
      invoke({ 'AC_SELECTED_FLUTTER_VERSION' => '' })
      expect(git_args).to eq("clone -b stable #{repo_url}")
    end

    it 'uses AC_SELECTED_FLUTTER_VERSION when it is the only one set' do
      invoke({ 'AC_SELECTED_FLUTTER_VERSION' => '3.13.9' })
      expect(git_args).to eq("clone -b 3.13.9 #{repo_url}")
    end

    it 'lets AC_FLUTTER_VERSION override AC_SELECTED_FLUTTER_VERSION' do
      invoke({ 'AC_SELECTED_FLUTTER_VERSION' => '3.13.9', 'AC_FLUTTER_VERSION' => '3.19.0' })
      expect(git_args).to eq("clone -b 3.19.0 #{repo_url}")
    end

    it 'falls back to AC_SELECTED_FLUTTER_VERSION when AC_FLUTTER_VERSION is empty' do
      invoke({ 'AC_SELECTED_FLUTTER_VERSION' => '3.13.9', 'AC_FLUTTER_VERSION' => '' })
      expect(git_args).to eq("clone -b 3.13.9 #{repo_url}")
    end

    it 'uses AC_FLUTTER_VERSION when AC_SELECTED_FLUTTER_VERSION is unset' do
      invoke({ 'AC_FLUTTER_VERSION' => 'master' })
      expect(git_args).to eq("clone -b master #{repo_url}")
    end
  end

  context 'PATH output' do
    it 'appends the cloned flutter/bin directory to PATH' do
      out, _err, _status = invoke
      expect(out).to include("PATH=#{expected_path}")
    end

    it 'writes the extended PATH to the Appcircle environment file' do
      invoke
      expect(File.read(env_file).strip).to eq("PATH=#{expected_path}")
    end

    it 'appends to the environment file instead of truncating it' do
      File.write(env_file, "AC_EXISTING_VAR=keep-me\n")
      invoke
      lines = File.readlines(env_file, chomp: true)
      expect(lines.first).to eq('AC_EXISTING_VAR=keep-me')
      expect(lines.last).to eq("PATH=#{expected_path}")
    end
  end

  context 'when git clone fails' do
    it 'exits non-zero and surfaces the git error' do
      _out, err, status = invoke(
        { 'AC_TEST_GIT_EXIT' => '128', 'AC_TEST_GIT_STDERR' => 'Remote branch not found' }
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('Remote branch not found')
    end

    it 'never runs flutter doctor' do
      invoke({ 'AC_TEST_GIT_EXIT' => '128', 'AC_TEST_GIT_STDERR' => 'Remote branch not found' })
      expect(flutter_args).to be_empty
    end

    it 'leaves the environment file untouched' do
      invoke({ 'AC_TEST_GIT_EXIT' => '128', 'AC_TEST_GIT_STDERR' => 'Remote branch not found' })
      expect(File.read(env_file)).to be_empty
    end
  end

  context 'when the clone produces no flutter binary' do
    it 'fails because flutter cannot be resolved from the appended PATH' do
      _out, err, status = invoke({ 'AC_TEST_GIT_SKIP_SDK' => '1' })
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('No such file or directory')
      expect(File.read(env_file)).to be_empty
    end
  end

  context 'when flutter doctor fails' do
    it 'exits non-zero and surfaces the flutter error' do
      _out, err, status = invoke(
        { 'AC_TEST_FLUTTER_EXIT' => '1', 'AC_TEST_FLUTTER_STDERR' => 'No valid Android SDK' }
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('No valid Android SDK')
    end

    it 'does not write the PATH to the environment file' do
      invoke({ 'AC_TEST_FLUTTER_EXIT' => '1', 'AC_TEST_FLUTTER_STDERR' => 'No valid Android SDK' })
      expect(File.read(env_file)).to be_empty
    end
  end

  context 'when the environment file cannot be written' do
    it 'exits non-zero after the toolchain has already run' do
      _out, err, status = invoke(
        { 'AC_ENV_FILE_PATH' => File.join(workdir, 'no-such-dir', 'ac_env_file') }
      )
      expect(status.exitstatus).not_to eq(0)
      expect(err).to include('No such file or directory')
      expect(flutter_args).to eq('doctor')
    end
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────

# Merges the in-process result with every subprocess dump, so lines that only
# run under `if __FILE__ == $PROGRAM_NAME` are counted as the covered lines
# they are.
def merged_main_coverage
  results = []

  if defined?(Coverage) && Coverage.running?
    results << begin
      Coverage.result(stop: false, clear: false)
    rescue ArgumentError
      Coverage.result
    end
  end

  child_dumps = Dir.glob(File.join(CHILD_COVERAGE_RESULTS, '*.dump')).sort
  child_dumps.each do |file|
    results << Marshal.load(File.binread(file))
  rescue StandardError
    next
  end

  merged = nil
  results.each do |result|
    key = result.keys.find { |path| path&.end_with?('main.rb') }
    next unless key

    data = result[key]
    if merged.nil?
      merged = data.dup
    elsif merged.size == data.size
      data.each_with_index do |count, i|
        next if count.nil? || merged[i].nil?

        merged[i] += count
      end
    end
  end

  [merged, child_dumps.size]
end

def print_coverage_report
  merged, child_runs = merged_main_coverage
  return puts("\nCoverage: main.rb not found in results") if merged.nil?

  lines     = merged.each_with_index.reject { |count, _| count.nil? }
  total     = lines.size
  covered   = lines.count { |count, _| count.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |count, _| count.to_i == 0 }.map { |_, i| i + 1 }

  color      = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar        = "\e[32m#{'█' * bar_filled}\e[90m#{'░' * (20 - bar_filled)}\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  puts "  \e[90mmerged from this process + #{child_runs} subprocess run(s)\e[0m"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color = true
    config.order = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(CHILD_COVERAGE_DIR)
  exit exit_code
end
