#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'fileutils'

OPTIONS = {systems: "x86-64_linux"}

op = OptionParser.new do |parser|
  parser.banner = "Usage: capkgs [options]"

  parser.on '--from URL', 'Nix store URL to fetch inputs from' do |v|
    OPTIONS[:from] = v
  end

  parser.on '--to URL', 'Nix store URL to copy CA outputs to' do |v|
    OPTIONS[:to] = v
  end

  parser.on '--only org/repo', 'Only update the given org/repo' do |v|
    OPTIONS[:only] = v
  end

  parser.on '--systems A,B', Array, "systems to process" do |v|
    OPTIONS[:systems] = v
  end

  parser.on '-h', '--help' do
    puts parser
    exit
  end
end

op.parse!

unless OPTIONS[:from]
  STDERR.puts "Missing required flag: --from"
  puts op
  exit 1
end

unless OPTIONS[:to]
  STDERR.puts "Missing required flag: --to"
  puts op
  exit 1
end

def sh(*args)
  pp args
  stdout, stderr, status = Open3.capture3(*args)
  pp Result.new(args, stdout, stderr, status)
end

class Result < Struct.new(:command, :stdout, :stderr, :status)
  def to_json(options)
    {command: command, stdout: stdout, stderr: stderr, status: status.exitstatus}.to_json(options)
  end
end

def process(pkg, flake_url, org, repo, tag, rev)
  pkg.merge!('org' => org, 'repo' => repo, 'tag' => tag, 'rev' => rev)

  return if pkg['fail']

  puts "Processing #{flake_url}"

  (merge(pkg) { process_eval(flake_url) }) &&
    (set(pkg, 'closure') { process_closure(flake_url) })

  puts "Marked #{flake_url} as failed" if pkg['fail']
end

def nix_make_content_addressed(out_path)
  content_addressed, status =
    sh 'nix', 'store', 'make-content-addressed', out_path.fetch('outputs').fetch('out'),
       '--json',
       '--from', OPTIONS.fetch(:from),
       '--to', OPTIONS.fetch(:to)
  content_addressed if status.success?
end

def fetch_git_branches(org_name, repo_name, branches, dest)
  url = "https://github.com/#{org_name}/#{repo_name}"

  refs_branches = branches.map do |branch|
    if File.file?(dest) && (found = JSON.parse(File.read(dest))[branch])
      next [branch, found]
    end

    result = sh('git', 'ls-remote', '--exit-code', url, "refs/heads/#{branch}")
    raise "failed to fetch branch '#{branch}' from #{url}" unless result.status.success?

    rev, _ = result.stdout.lines.first.strip.split
    [branch, rev]
  end

  puts "writing #{dest}"
  File.write(dest, JSON.pretty_generate(refs_branches.to_h))
end

def fetch_git_tags(org_name, repo_name, pattern, dest)
  url = "https://github.com/#{org_name}/#{repo_name}"
  result = sh('git', 'ls-remote', '--exit-code', url, 'refs/tags/*')
  return {} unless result.status.success?

  refs_tags = result.stdout.lines.grep(Regexp.new(pattern)).map do |line|
    rev, ref = line.strip.split
    [ref.sub(%r!^refs/(tags|heads)/!, ''), rev]
  end

  puts "writing #{dest}"
  File.write(dest, JSON.pretty_generate(refs_tags.to_h))
end

def fetch_github_releases(org_name, repo_name, dest)
  releases_url = "https://api.github.com/repos/#{org_name}/#{repo_name}/releases"
  # Use curl here to take advantage of netrc for the token without having to parse it
  curl_result = sh('curl', '-s', '--fail-with-body', releases_url)
  return {} unless curl_result.status.success?

  tag_names = JSON.parse(curl_result.stdout).map{|release| release.fetch('tag_name') }
  refs_tags = tag_names.map do |tag_name|
    if File.file?(dest) && (found = JSON.parse(File.read(dest))[tag_name])
      next [tag_name, found]
    end

    tags_url = "https://github.com/#{org_name}/#{repo_name}"
    tags_result = sh('git', 'ls-remote', '--exit-code', '--tags', tags_url, tag_name)
    raise "Failed to fetch #{tag_name} from #{tags_url}" unless tags_result.status.success?

    pattern =  %r!refs/tags/#{Regexp.escape(tag_name)}!
    matching = tags_result.stdout.lines.grep(pattern) 
    rev, ref = matching.first.strip.split
    [tag_name, rev]
  end

  puts "writing #{dest}"
  File.write(dest, JSON.pretty_generate(refs_tags.to_h))
end

def update_releases
  JSON.parse(File.read('projects.json')).flat_map do |org_name, repos|
    repos.flat_map do |repo_name, config|
      dest = "releases/#{org_name}/#{repo_name}.json"
      FileUtils.mkdir_p(File.dirname(dest))

      case config.fetch('type')
      when 'git_branches'
        fetch_git_branches(org_name, repo_name, config.fetch('branches'), dest)
      when 'git_tags'
        fetch_git_tags(org_name, repo_name, config.fetch('pattern'), dest)
      when 'github_releases'
        fetch_github_releases(org_name, repo_name, dest)
      else
        raise "Invalid project type: #{config.type}"
      end
    end
  end
end

def each_package
  JSON.parse(File.read("projects.json")).flat_map do |org_name, repos|
    repos.flat_map do |repo_name, config|
      JSON.parse(File.read("releases/#{org_name}/#{repo_name}.json")).flat_map do |version, commit|
        config.fetch('packages').flat_map do |package|
          yield Package.new(package, version, commit, org_name, repo_name, {}, [], {})
        end
      end
    end
  end
end

class Package < Struct.new(
    :name,
    :version, 
    :commit,
    :org_name,
    :repo_name,
    :meta,
    :out,
    :closure,
    :pname,
    :system)

  def flake_url
    name.gsub("${tag}", commit).gsub("${system}", "x86_64-linux")
  end

  def eval_file_path; "evals/#{flake_url}.json"; end
  def build_file_path; "builds/#{flake_url}.json"; end
  def closure_file_path; "closures/#{flake_url}.json"; end

  CODE = <<~CODE.gsub(/\s+/, ' ').strip
    d: {
      inherit (d) system;
      pname = d.pname or d.name;
      version = d.version or "";
      meta = d.meta or {};
    }
  CODE

  def nix_eval
    process(eval_file_path, [
      'nix', 'eval', flake_url,
      '--accept-flake-config',
      '--no-write-lock-file',
      '--json',
      '--apply', CODE
    ]) do |stdout|
      self.meta = stdout.fetch('meta')
      self.pname = stdout.fetch('pname')
      self.version = stdout.fetch('version')
      self.system = stdout.fetch('system')
    end
  end

  def nix_build
    process(build_file_path, [
      'nix', 'build', flake_url,
      '--accept-flake-config',
      '--no-write-lock-file',
      '--no-link',
      '--json'
    ]) do |stdout|
      self.out = stdout
    end
  end

  def nix_store_make_content_addressed
    process(closure_file_path, [
      "nix", "store", "make-content-addressed", out.first.fetch('outputs').fetch('out'), "--json",
      '--from', OPTIONS.fetch(:from),
      '--to', OPTIONS.fetch(:to)
    ]) do |stdout|
      from, to = stdout.fetch('rewrites').first
      self.closure = { fromPath: from, toPath: to, fromStore: "https://cache.iog.io" }
    end
  end

  def mkdirs
    [eval_file_path, build_file_path, closure_file_path].each do |path|
      FileUtils.mkdir_p(File.dirname(path))
    end
  end

  def to_h
    {
      closure: closure,
      meta: meta,
      org: org_name,
      repo: repo_name,
      rev: commit,
      system: system,
      tag: version,
    }
  end

  def process(path, cmd)
    if File.file?(path)
      parsed = JSON.parse(File.read(path))
      (parsed.fetch('status') == 0) && yield(JSON.parse(parsed.fetch('stdout')))
    else
      result = sh(*cmd)
      File.write(path, JSON.pretty_generate(result))
      yield(JSON.parse(result.stdout)) if result.status.success?
    end
  end
end

trap(:INT){ exit }

update_releases

valid = {}

each_package do |pkg|
  pkg.mkdirs
  pkg.nix_eval &&
  pkg.nix_build &&
  pkg.nix_store_make_content_addressed
  valid[pkg.flake_url] = pkg.to_h if pkg.closure.any?
end

File.write('packages.json', JSON.pretty_generate(valid.sort.to_h)) 