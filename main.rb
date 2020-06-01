require 'open3'
require 'yaml'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

ac_flutter_version = get_env_variable("AC_SELECTED_FLUTTER_VERSION") || "stable"
flutter_repo_url = "https://github.com/flutter/flutter.git"

puts "Selected flutter version is #{ac_flutter_version}"

def run_command(command)
    puts "@[command] #{command}"
    status = nil
    stdout_str = nil
    stderr_str = nil

    Open3.popen3(command) do |stdin, stdout, stderr, wait_thr|
        stdout.each_line do |line|
            puts line
        end
        stdout_str = stdout.read
        stderr_str = stderr.read
        status = wait_thr.value
    end

    unless status.success?
        puts stderr_str
    end
end

run_command("git clone -b #{ac_flutter_version} #{flutter_repo_url}")

pwd = Dir.pwd
ENV["PATH"] = "#{ENV["PATH"]}:#{pwd}/flutter/bin/"

puts "PATH=#{ENV["PATH"]}"
run_command("flutter doctor")

# Write Environment Variable
open(env_var_path, 'a') { |f|
  f.puts "PATH=#{ENV["PATH"]}"
}

exit 0