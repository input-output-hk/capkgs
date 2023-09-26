#!/usr/bin/env crystal

require "json"
require "option_parser"
require "file_utils"

class Config
  property from : String?
  property to : String?
  property nix_store : String?
  property systems : Array(String)?

  def parse
    OptionParser.parse do |parser|
      parser.banner = "Usage: capkgs [options]"

      parser.on "--from=URL", "Nix store URL to fetch inputs from" { |v| @from = v }
      parser.on "--to=URL", "Nix store URL to copy CA outputs to" { |v| @to = v }
      parser.on "--systems=A,B", "systems to process" { |v| @systems = v.split.map(&.strip) }
      parser.on "--nix-store=STORE", "store URI" { |v| @nix_store = v }

      parser.on "-h", "--help", "Show this help" do
        puts parser
        exit
      end
    end

    raise "Missing required flag: --from" unless from_value = @from
    raise "Missing required flag: --to" unless to_value = @to
    raise "Missing required flag: --systems" unless systems_value = @systems
    raise "Missing required flag: --nix-store" unless nix_store_value = @nix_store

    Valid.new(from_value, to_value, systems_value, nix_store_value)
  end

  struct Valid
    property from : String
    property to : String
    property systems : Array(String)
    property nix_store : String

    def initialize(@from, @to, @systems, @nix_store)
    end
  end
end

config = Config.new.parse
pp! config

def sh(command : String, *args : String)
  output = IO::Memory.new
  error = IO::Memory.new
  puts Process.quote_posix([command, *args])
  status = Process.run(command, args, output: output, error: error)

  Result.new([command, *args], output.to_s, error.to_s, status.exit_code).tap do |result|
    puts result.status.inspect

    puts "STDOUT:"
    puts result.stdout

    puts "STDERR:"
    puts result.stderr
  end
end

def fetch_git_branches(org_name, repo_name, branches, dest)
  url = "https://github.com/#{org_name}/#{repo_name}"

  refs_branches = branches.map do |branch|
    if File.file?(dest) && (found = JSON.parse(File.read(dest))[branch])
      next [branch, found.as_s]
    end

    result = sh("git", "ls-remote", "--exit-code", url, "refs/heads/#{branch}")
    raise "failed to fetch branch '#{branch}' from #{url}" unless result.success?

    rev, _ = result.stdout.lines.first.strip.split
    [branch, rev]
  end

  puts "writing #{dest}"
  File.write(dest, refs_branches.to_h.to_pretty_json)
end

def fetch_git_tags(org_name, repo_name, pattern, dest)
  url = "https://github.com/#{org_name}/#{repo_name}"
  result = sh("git", "ls-remote", "--exit-code", url, "refs/tags/*")
  return {} of String => String unless result.success?

  rpattern = Regex.new(pattern)
  refs_tags = result.stdout.lines.select { |line| line =~ rpattern }.map do |line|
    rev, ref = line.strip.split
    [ref.sub(/^refs\/(tags|heads)\//, ""), rev]
  end

  puts "writing #{dest}"
  File.write(dest, refs_tags.to_h.to_pretty_json)
end

def fetch_github_releases(org_name, repo_name, dest)
  releases_url = "https://api.github.com/repos/#{org_name}/#{repo_name}/releases"
  # Use curl here to take advantage of netrc for the token without having to parse it
  curl_result = sh("curl", "-s", "--fail-with-body", releases_url)
  return {} of String => String unless curl_result.success?

  tag_names = Array(GithubRelease).from_json(curl_result.stdout).map { |release| release.tag_name }
  refs_tags = tag_names.map do |tag_name|
    if File.file?(dest) && (found = JSON.parse(File.read(dest))[tag_name])
      next [tag_name, found.as_s]
    end

    tags_url = "https://github.com/#{org_name}/#{repo_name}"
    tags_result = sh("git", "ls-remote", "--exit-code", "--tags", tags_url, tag_name)
    raise "Failed to fetch #{tag_name} from #{tags_url}" unless tags_result.success?

    pattern = /refs\/tags\/#{Regex.escape(tag_name)}/
    matching = tags_result.stdout.lines.select { |line| line =~ pattern }
    rev, ref = matching.first.strip.split
    [tag_name, rev]
  end

  puts "writing #{dest}"
  File.write(dest, refs_tags.to_h.to_pretty_json)
end

def update_releases
  Projects.from_json(File.read("projects.json")).each do |org_name, repos|
    repos.flat_map do |repo_name, repo|
      dest = "releases/#{org_name}/#{repo_name}.json"
      FileUtils.mkdir_p(File.dirname(dest))

      case repo
      when Repo::GitBranches
        fetch_git_branches(org_name, repo_name, repo.branches, dest)
      when Repo::GitTags
        fetch_git_tags(org_name, repo_name, repo.pattern, dest)
      when Repo::GithubReleases
        fetch_github_releases(org_name, repo_name, dest)
      else
        raise "Invalid project type: #{repo.type}"
      end
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
end

struct Repo
  include JSON::Serializable

  use_json_discriminator "type", {
    git_branches:    GitBranches,
    git_tags:        GitTags,
    github_releases: GithubReleases,
  }

  struct GitBranches
    include JSON::Serializable
    property packages : Array(String)
    property branches : Array(String)
  end

  struct GithubReleases
    include JSON::Serializable
    property packages : Array(String)
  end

  struct GitTags
    include JSON::Serializable
    property packages : Array(String)
    property pattern : String
  end
end

alias Repos = Hash(String, Repo::GitBranches | Repo::GithubReleases | Repo::GitTags)
alias Projects = Hash(String, Repos)
alias Releases = Hash(String, String)

struct Package
  include JSON::Serializable

  @[JSON::Field(ignore: true)]
  property config : ::Config::Valid

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

  def initialize(@config, @system, @name, @version, @commit, @org_name, @repo_name)
  end

  def <=>(other : Package)
    flake_url <=> other.flake_url
  end

  def flake_url
    name.gsub("${tag}", commit).gsub("${system}", @system)
  end

  def eval_file_path
    "cache/evals/#{flake_url}.json"
  end

  def build_file_path
    "cache/builds/#{flake_url}.json"
  end

  def closure_file_path
    "cache/closures/#{flake_url}.json"
  end

  CODE = <<-CODE.gsub(/\s+/, ' ').strip
    d: {
      pname = d.pname or d.name or null;
      version = d.version or null;
      meta = d.meta or null;
    }
  CODE

  def nix_eval
    process(eval_file_path,
      "nix", "eval", flake_url,
      "--eval-store", "auto",
      "--store", config.nix_store,
      "--accept-flake-config",
      "--no-write-lock-file",
      "--json",
      "--apply", CODE,
    ) do |stdout|
      @meta = stdout["meta"].as_h
      @pname = stdout["pname"].as_s
      @version = stdout["version"].as_s
    end
  end

  def nix_build
    process(build_file_path,
      "nix", "build", flake_url,
      "--eval-store", "auto",
      "--store", config.nix_store,
      "--accept-flake-config",
      "--no-write-lock-file",
      "--no-link",
      "--json",
    ) do |stdout|
      stdout.dig?(0, "outputs", "out").try { |o| @output = o.as_s }
    end
  end

  def nix_store_make_content_addressed(config)
    path = output.not_nil!
    process(closure_file_path,
      "nix", "store", "make-content-addressed", path, "--json",
      "--eval-store", "auto",
      "--store", config.nix_store,
      "--from", config.from,
      "--to", config.to,
    ) do |stdout|
      stdout.dig?("rewrites", path).try { |to_path|
        @closure = {fromPath: path, toPath: to_path.as_s, fromStore: config.from}
      }
    end
  end

  def mkdirs
    [eval_file_path, build_file_path, closure_file_path].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
    end
  end

  def process(path, command : String, *args)
    if File.file?(path)
      puts "Skipping #{path}"
      result = Result.from_json(File.read(path))
      (result.status == 0) && yield(JSON.parse(result.stdout))
    else
      result = sh(command, *args)
      File.write(path, result.to_pretty_json)
      yield(JSON.parse(result.stdout)) if result.success?
    end
  end
end

def each_package(config, &block : Package -> Nil)
  packages =
    config.systems.map do |system|
      Projects.from_json(File.read("projects.json")).map do |org_name, repos|
        repos.map do |repo_name, repo|
          Releases.from_json(File.read("releases/#{org_name}/#{repo_name}.json")).map do |version, commit|
            repo.packages.map do |package|
              Package.new(config, system, package, version, commit, org_name, repo_name)
            end
          end
        end
      end
    end

  packages.flatten.sort.each(&block)
end

Signal::INT.trap { exit }

update_releases

valid = {} of String => Package

each_package(config) do |pkg|
  pkg.mkdirs
  pkg.nix_eval &&
    pkg.nix_build &&
    pkg.nix_store_make_content_addressed(config)
  valid[pkg.flake_url] = pkg if pkg.closure
end

File.open("packages.json", "w+") { |fd| valid.to_pretty_json(fd) }
