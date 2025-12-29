#!/usr/bin/env crystal

require "json"
require "option_parser"
require "file_utils"
require "log"
require "http/client"

class CAPkgs
  property config : Config::Valid

  def initialize(@config)
  end

  def run
    update_releases
    valid = update_packages
    commit(valid)
  end

  def update_packages
    exclusions = load_exclusions

    ({} of String => CAPkgs::Package).tap do |valid|
      each_package do |pkg|
        next if exclusions.includes?(pkg.flake_url)

        pkg.mkdirs
        pkg.nix_eval &&
          pkg.nix_build &&
          pkg.nix_copy_original &&
          pkg.nix_store_make_content_addressed &&
          pkg.nix_copy_closure

        valid[pkg.flake_url] = pkg if pkg.closure
      end
    end
  end

  def load_exclusions
    return [] of String unless File.exists?("exclusions.json")
    data = JSON.parse(File.read("exclusions.json")).as_h.keys
    data
  end

  def each_package(&block : Package -> Nil)
    packages =
      config.systems.map do |system|
        Projects.from_json(File.read("projects.json")).map do |org_name, repos|
          repos.map do |repo_name, repo|
            %w[releases refs].map do |kind|
              src = "cache/#{kind}/#{org_name}/#{repo_name}.json"
              next unless File.file?(src)
              Releases.from_json(File.read(src)).map do |version, commit|
                repo.packages.map do |package|
                  Package.new(config, system, package, version, commit, org_name, repo_name)
                end
              end
            end
          end
        end
      end

    packages.flatten.compact.sort.each(&block)
  end

  def sh(command : String, *args : String)
    self.class.sh(config, command, *args)
  end

  def self.sh(config : Config::Valid, command : String, *args : String)
    output = IO::Memory.new
    error = IO::Memory.new

    multi_output = IO::MultiWriter.new(output)
    multi_error = IO::MultiWriter.new(error)

    Log.debug {
      multi_output = IO::MultiWriter.new(output, STDOUT)
      multi_error = IO::MultiWriter.new(error, STDERR)
      "sh logging enabled"
    }

    Log.info { Process.quote_posix([command, *args]) }
    status = Process.run(command, args, output: multi_output, error: multi_error)

    Result.new([command, *args], output.to_s, error.to_s, status.exit_code).tap do |result|
      unless result.success?
        Log.warn { "exit status: #{result.status.inspect}" }
      end
    end
  end

  def update_releases
    return unless config.update

    Projects.from_json(File.read("projects.json")).each do |org_name, repos|
      repos.each do |repo_name, repo|
        if refs = repo.refs
          dest = "cache/refs/#{org_name}/#{repo_name}.json"
          FileUtils.mkdir_p(File.dirname(dest))
          fetch_git_refs(org_name, repo_name, refs, dest)
        end

        if repo.github_releases
          dest = "cache/releases/#{org_name}/#{repo_name}.json"
          FileUtils.mkdir_p(File.dirname(dest))
          fetch_github_releases(org_name, repo_name, dest)
        end
      end
    end
  end

  def fetch_git_refs(org_name, repo_name, ref_patterns, dest)
    url = "https://github.com/#{org_name}/#{repo_name}"
    result = sh("git", "ls-remote", "--exit-code", url)
    raise "Couldn't fetch git refs for '#{url}'" unless result.success?

    # Ref patterns will not be automatically dereferenced.
    # To dereference, a ref pattern should have a suffix of: `\\^\\{\\}$`
    # The resulting package name from a dereferenced pattern will *NOT* include the `^{}` suffix.
    # The shortRev in the package name can be used to infer dereferencing.
    refs_tags = ref_patterns.flat_map do |ref_pattern|
      regex = Regex.new(ref_pattern)
      result.stdout.lines
        .map { |line| line.strip.split }
        .select { |(rev, ref)| ref =~ regex }
        .map do |(rev, ref)|
          [ref.sub(%r(^refs/[^/]+/), "").sub(%r(\^\{\}$), ""), rev]
        end
    end

    Log.info { "refs count: #{refs_tags.size}" }
    Log.info { "refs: #{refs_tags.to_h.keys.inspect}" }
    Log.debug { "writing #{dest}" }
    File.write(dest, refs_tags.to_h.to_pretty_json)
  end

  def fetch_github_releases(org_name, repo_name, dest)
    releases_url = "https://api.github.com/repos/#{org_name}/#{repo_name}/releases"
    # Use curl here to take advantage of netrc for the token without having to parse it
    curl_result = sh("curl", "--http1.1", "--show-headers", "--netrc", "-L", "-s", "--fail-with-body", releases_url)
    raise "Couldn't fetch releases for '#{releases_url}'" unless curl_result.success?

    releases = HTTP::Client::Response.from_io(IO::Memory.new(curl_result)) do |response|
      pp! response.headers
      Array(GithubRelease).from_json(response.body_io)
    end

    # If running locally with required privileges, draft releases may be
    # included causing an exception if not filtered.
    tag_names = releases.reject(&.draft).map { |release| release.tag_name }
    refs_tags = tag_names.map do |tag_name|
      # Once we record a tag, prevent it from updating
      if File.file?(dest) && (found = JSON.parse(File.read(dest))[tag_name]?)
        next [tag_name, found.as_s]
      end

      tags_url = "https://github.com/#{org_name}/#{repo_name}"

      # If a tag associated dereferenced object exists, use it preferentially.
      # Only annotated tags will have a dereferenced object available.
      tags_result = sh("git", "ls-remote", "--exit-code", "--tags", tags_url, tag_name + "^{}")
      unless tags_result.success?
        tags_result = sh("git", "ls-remote", "--exit-code", "--tags", tags_url, tag_name)
        raise "Failed to fetch #{tag_name} from #{tags_url}" unless tags_result.success?
      end

      pattern = /refs\/tags\/#{Regex.escape(tag_name)}/
      matching = tags_result.stdout.lines.select { |line| line =~ pattern }
      rev, ref = matching.first.strip.split
      [tag_name, rev]
    end

    Log.info { "releases count: #{refs_tags.size}" }
    Log.info { "releases: #{refs_tags.to_h.inspect}" }
    Log.debug { "writing #{dest}" }
    File.write(dest, refs_tags.to_h.to_pretty_json)
  end

  def commit(new_pkgs : Hash(String, Package))
    return unless config.commit

    File.open("packages.tmp.json", "w+") { |fd| new_pkgs.to_pretty_json(fd) }

    if File.file?("packages.json")
      old = File.open("packages.json", "r") { |fd| Hash(String, JSON::Any).from_json(fd) }
      added = new_pkgs.keys - old.keys
      removed = old.keys - new_pkgs.keys

      if added.empty? && removed.empty?
        Log.info { "No packages added or removed, will not commit" }
        return
      end

      msg = String.build do |io|
        io << "Update #{Time.utc.to_rfc3339}\n\n"
        if added.any?
          io << "added:\n"
          added.each do |name|
            Log.debug { "Added: #{name}" }
            io << "* #{name}\n"
          end
        end

        if removed.any?
          io << "removed:\n"
          removed.each do |name|
            Log.debug { "Removed: #{name}" }
            io << "* #{name}\n"
          end
        end
      end

      Log.info { msg }

      FileUtils.mv("packages.tmp.json", "packages.json")

      raise "Couldn't add packages.json" unless sh("git", "add", "packages.json").success?
      raise "Couldn't commit result" unless sh("git", "commit", "-m", msg).success?
      raise "Couldn't push changes" unless sh("git", "push").success?
    end
  end

  class Config
    property from_store : String?
    property to : String?
    property systems : Array(String)?
    property update = true
    property commit = true

    def parse
      OptionParser.parse do |parser|
        parser.banner = "Usage: capkgs [options]"

        parser.on "--from-store=URL", "Public cache URL that users fetch closures from" { |v| @from_store = v }
        parser.on "--to=URL", "Nix store URL to copy CA outputs to" { |v| @to = v }
        parser.on "--systems=A,B", "systems to process" { |v| @systems = v.split.map(&.strip) }
        parser.on "--no-update", "skip updating release info" { |v| @update = false }
        parser.on "--no-commit", "skip commiting packages.json" { |v| @commit = false }

        parser.on "-h", "--help", "Show this help" do
          puts parser
          exit
        end
      end

      raise "Missing required flag: --from-store" unless from_store_value = @from_store
      raise "Missing required flag: --to" unless to_value = @to
      raise "Missing required flag: --systems" unless systems_value = @systems

      Valid.new(from_store_value, to_value, systems_value, @update, @commit)
    end

    struct Valid
      property from_store : String
      property to : String
      property systems : Array(String)
      property update : Bool
      property commit : Bool

      def initialize(@from_store, @to, @systems, @update, @commit)
      end
    end
  end

  struct Result
    include JSON::Serializable
    property command : Array(String)
    property stdout : String
    property stderr : String
    property status : Int32

    def initialize(@command, @stdout, @stderr, @status)
    end

    def success?
      status == 0
    end
  end

  struct GithubRelease
    include JSON::Serializable
    property tag_name : String
    property draft : Bool = false
  end

  struct Repo
    include JSON::Serializable
    property packages : Array(String)
    property refs : Array(String)?
    property github_releases : Bool = false
  end

  alias Repos = Hash(String, Repo)
  alias Projects = Hash(String, Repos)
  alias Releases = Hash(String, String)

  struct Package
    include JSON::Serializable

    @[JSON::Field(ignore: true)]
    property config : CAPkgs::Config::Valid

    property name : String
    property version : String
    property commit : String
    property org_name : String
    property repo_name : String
    property meta : Hash(String, JSON::Any)?
    property output : String?
    property closure : NamedTuple(fromPath: String, toPath: String, fromStore: String)?
    property pname : String?
    property system : String
    property exeName : String?

    def initialize(@config, @system, @name, @version, @commit, @org_name, @repo_name)
    end

    def sh(command, *args)
      CAPkgs.sh(config, command, *args)
    end

    def <=>(other : Package)
      flake_url <=> other.flake_url
    end

    def flake_url
      name.gsub("${tag}", commit).gsub("${system}", @system)
    end

    def cache_path(file)
      File.join "cache", flake_url, "#{file}.json"
    end

    def eval_file_path
      cache_path "eval"
    end

    def build_file_path
      cache_path "build"
    end

    def closure_file_path
      cache_path "closure"
    end

    def copy_original_file_path
      cache_path "original_copy"
    end

    def copy_closure_file_path
      cache_path "closure_copy"
    end

    CODE = <<-CODE.gsub(/\s+/, ' ').strip
      d: {
        pname = d.pname or d.name or null;
        version = d.version or null;
        meta = d.meta or null;
        exeName = d.exeName or null;
      }
    CODE

    def nix_eval
      process(eval_file_path, true,
        "nix", "eval", flake_url,
        "--accept-flake-config",
        "--no-write-lock-file",
        "--json",
        "--apply", CODE,
      ) do |stdout|
        @meta = stdout["meta"].as_h
        @pname = stdout["pname"].as_s
        @exeName = stdout["exeName"].as_s?
        true
      end
    end

    def nix_build
      process(build_file_path, true,
        "nix", "build", flake_url,
        "--accept-flake-config",
        "--no-write-lock-file",
        "--no-link",
        "--json",
      ) do |stdout|
        stdout.dig?(0, "outputs", "out").try { |o| @output = o.as_s }
      end
    end

    def nix_copy_original
      process(copy_original_file_path, false,
        "nix", "copy", flake_url,
        "--to", config.to,
        "--accept-flake-config",
        "--no-write-lock-file",
      ) do |stdout|
        true
      end
    end

    def nix_store_make_content_addressed
      path = output.not_nil!
      process(closure_file_path, true,
        "nix", "store", "make-content-addressed", flake_url, "--json",
        "--to", config.to,
        "--accept-flake-config",
        "--no-write-lock-file",
      ) do |stdout|
        stdout.dig?("rewrites", path).try { |to_path|
          @closure = {fromPath: path, toPath: to_path.as_s, fromStore: config.from_store}
        }
      end
    end

    def nix_copy_closure
      process(copy_closure_file_path, false,
        "nix", "copy", closure.not_nil![:toPath],
        "--to", config.to,
        "--accept-flake-config",
        "--no-write-lock-file",
      ) do |stdout|
        true
      end
    end

    def mkdirs
      [eval_file_path, build_file_path, copy_original_file_path, copy_closure_file_path, closure_file_path].each do |path|
        FileUtils.mkdir_p(File.dirname(path))
      end
    end

    def process(path, expect_json, command : String, *args)
      result =
        if File.file?(path)
          Log.debug { "File exists: #{path}" }
          Result.from_json(File.read(path))
        else
          Log.debug { "File create: #{path}" }
          sh(command, *args).tap { |r|
            File.write(path, r.to_pretty_json)
          }
        end

      if result.success? && expect_json
        yield(JSON.parse(result.stdout))
      else
        result.success?
      end
    end
  end
end

Signal::INT.trap { exit }

Log.setup_from_env(
  default_level: Log::Severity::Info,
  default_sources: "*",
  log_level_env: "LOG_LEVEL",
  backend: Log::IOBackend.new(io: STDERR))

CAPkgs.new(CAPkgs::Config.new.parse).run
