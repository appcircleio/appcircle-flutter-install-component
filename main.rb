require 'open3'
require 'yaml'
require 'json'
require 'digest'
require 'fileutils'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def get_version(component_version,config_version)
    return config_version == nil ? component_version : config_version
end

env_var_path = get_env_variable("AC_ENV_FILE_PATH") || abort('Missing environment variable path.')
ac_component_version = get_env_variable("AC_SELECTED_FLUTTER_VERSION") || "stable"
ac_config_version = get_env_variable("AC_FLUTTER_VERSION")
ac_flutter_version = get_version(ac_component_version,ac_config_version)
flutter_repo_url = "https://github.com/flutter/flutter.git"
ac_flutter_storage_base_url = (get_env_variable("AC_FLUTTER_STORAGE_BASE_URL") || "https://storage.googleapis.com").chomp("/")
flutter_releases_url = "#{ac_flutter_storage_base_url}/flutter_infra_release/releases"
# hw.optional.arm64 is 1 on Apple silicon, also when Ruby runs under Rosetta.
flutter_arch = `sysctl -n hw.optional.arm64 2>/dev/null`.strip == "1" ? "arm64" : "x64"

puts "Selected flutter version is #{ac_flutter_version}"

def run_command(command)
    puts "@@[command] #{command}"
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
        raise stderr_str
    end
end

# stable and beta resolve to the current release of the channel. Releases older than 2.12
# have no dart_sdk_arch field; they are x64 builds.
def find_release(manifest, version, arch)
    releases = manifest["releases"]
    if ["stable", "beta"].include?(version)
        hash = manifest["current_release"][version]
        releases = releases.select { |r| r["hash"] == hash && r["channel"] == version }
    else
        releases = releases.select { |r| r["version"].sub(/\Av/, "") == version.sub(/\Av/, "") }
    end
    return releases.find { |r| r["dart_sdk_arch"] == arch } || releases.find { |r| r["dart_sdk_arch"].nil? }
end

manifest = nil
begin
    run_command("curl -fsSL --retry 3 -o releases_macos.json #{flutter_releases_url}/releases_macos.json")
    manifest = JSON.parse(File.read("releases_macos.json"))
rescue StandardError => e
    puts "Flutter release manifest could not be read: #{e}"
end
release = manifest.nil? ? nil : find_release(manifest, ac_flutter_version, flutter_arch)

if release
    puts "Resolved flutter version is #{release["version"]} (#{release["channel"]}, #{flutter_arch})"
    flutter_sdk_path = "#{Dir.home}/flutter-sdk/#{release["version"]}"
    sha_file = "#{flutter_sdk_path}/.sha256"
    if File.exist?(sha_file) && File.read(sha_file).strip == release["sha256"]
        puts "Flutter #{release["version"]} is already installed at #{flutter_sdk_path}, skipping download."
    else
        archive_url = "#{flutter_releases_url}/#{release["archive"]}"
        puts "Archive URL: #{archive_url}"
        run_command("curl -fsSL --retry 3 -o flutter.zip #{archive_url}")
        checksum = Digest::SHA256.file("flutter.zip").hexdigest
        raise "Checksum mismatch: expected #{release["sha256"]}, got #{checksum}" unless checksum == release["sha256"]
        puts "Checksum verified: #{checksum}"
        FileUtils.rm_rf(flutter_sdk_path)
        FileUtils.mkdir_p(flutter_sdk_path)
        run_command("ditto -x -k flutter.zip #{flutter_sdk_path}")
        FileUtils.rm_f("flutter.zip")
        File.write(sha_file, release["sha256"])
    end
    flutter_path = "#{flutter_sdk_path}/flutter"
else
    # Branches and commits have no release archive, so they still need GitHub.
    _, status = Open3.capture2e("git ls-remote --exit-code #{flutter_repo_url} HEAD")
    raise "Flutter #{ac_flutter_version} is only available via git; use a released version" unless status.success?
    run_command("git clone -b #{ac_flutter_version} #{flutter_repo_url}")
    flutter_path = "#{Dir.pwd}/flutter"
end

# Every flutter command checks GitHub for a newer version first; without internet access it waits about 75 s.
FileUtils.mkdir_p("#{flutter_path}/bin/cache")
now = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S.000")
File.write("#{flutter_path}/bin/cache/flutter_version_check.stamp", JSON.generate({ "lastTimeVersionWasChecked" => now, "lastKnownRemoteVersion" => now, "lastTimeWarningWasPrinted" => now }))

ENV["PATH"] = "#{ENV["PATH"]}:#{flutter_path}/bin/"

puts "PATH=#{ENV["PATH"]}"
run_command("flutter doctor")

# Write Environment Variable
open(env_var_path, 'a') { |f|
  f.puts "PATH=#{ENV["PATH"]}"
}

exit 0
