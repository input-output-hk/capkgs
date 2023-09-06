#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'

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
  result, status = Open3.capture2(*args)
  pp result
  pp status unless status.success?
  [result, status]
end

def process(pkg, flake_url, org, repo, tag, rev)
  pkg.merge!('org' => org, 'repo' => repo, 'tag' => tag, 'rev' => rev)

  # return if pkg['fail']

  puts "Processing #{flake_url}"

  (merge(pkg) { process_eval(flake_url) }) &&
    (set(pkg, 'closure') { process_closure(flake_url) })

  puts "Marked #{flake_url} as failed" if pkg['fail']
end

def set(pkg, key)
  return true if pkg[key]

  if (value = yield)
    pkg[key] = value
  else
    pkg['fail'] = true
    false
  end
end

def merge(pkg)
  return true if pkg['system']

  if (value = yield)
    pkg.merge!(value)
  else
    pkg['fail'] = true
    false
  end
end

def process_eval(flake_url)
  puts "eval #{flake_url}"

  result, status = sh 'nix', 'eval', '--json', '--no-write-lock-file', flake_url, '--apply', %[
    d: {
      inherit (d) system;
      pname = d.pname or d.name;
      version = d.version or "";
      meta = d.meta or {};
    } ]
  return unless status.success?

  JSON.parse(result)
end

def process_closure(flake_url)
  puts "closure #{flake_url}"

  return unless (out_path = nix_build(flake_url))
  return unless (content_addressed = nix_make_content_addressed(out_path))

  rewrites = JSON.parse(content_addressed).fetch('rewrites')

  raise "Encountered more than one rewrite object: #{rewrites.inspect}" if rewrites.size > 1

  from_path, to_path = rewrites.first
  { fromPath: from_path, toPath: to_path, fromStore: OPTIONS.fetch(:from) }
end

def nix_build(flake_url)
  out_path, status = sh 'nix', 'build', '--no-link', '--no-write-lock-file', '--print-out-paths', flake_url
  out_path.strip if status.success?
end

def nix_make_content_addressed(out_path)
  content_addressed, status =
    sh 'nix', 'store', 'make-content-addressed', out_path,
       '--json',
       '--from', OPTIONS.fetch(:from),
       '--to', OPTIONS.fetch(:to)
  content_addressed if status.success?
end

def update_from_release(store, org, repo, flake_url, tag, commit)
  store[flake_url] ||= {}
  process(store[flake_url], flake_url, org, repo, tag, commit)
  File.write('packages.json', JSON.pretty_generate(store))
end

def prepare(store, org, repo, packages)
  JSON.parse(File.read("releases/#{org}/#{repo}.json")).each do |tag, commit|
    packages.each do |package|
      OPTIONS.fetch(:systems).each do |system|
        flake_url = package.gsub('${tag}', tag).gsub('${system}', system)
        update_from_release(store, org, repo, flake_url, tag, commit)
      end
    end
  end
end

File.file?('packages.json') || File.write('packages.json', '{}')

store = JSON.parse(File.read('packages.json'))

JSON.parse(File.read('projects.json')).each do |org, repos|
  repos.each do |repo, repo_config|
    if (OPTIONS[:only] && "#{org}/#{repo}" != OPTIONS[:only])
      pp org => repo
      next
    end
    prepare(store, org, repo, repo_config.fetch('packages'))
  end
end
