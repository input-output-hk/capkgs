#!/usr/bin/env ruby
# frozen_string_literal: true

require 'English'
require 'json'
require 'open3'

KEY = '/run/agenix/nix'
ENDPOINT = 'fc0e8a9d61fc1f44f378bdc5fdc0f638.r2.cloudflarestorage.com'
SYSTEMS = %w[x86_64-linux].freeze

def sh(*args)
  pp args
  result, status = Open3.capture2(*args)
  pp result
  pp status unless status.success?
  [result, status]
end

def process(pkg, flake_url, org, repo, tag, rev)
  pkg.merge!('org' => org, 'repo' => repo, 'tag' => tag, 'rev' => rev)

  clean(pkg)

  return if pkg['fail']

  (merge(pkg) { process_eval(flake_url) }) &&
    (set(pkg, 'closure') { process_closure(flake_url) })

  puts "Marked #{flake_url} as failed" if pkg['fail']
end

def clean(pkg)
  pkg.delete('closure') if pkg['closure'] == {}
  pkg.delete('closure') if pkg['closure'].instance_of?(Array)
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

def process_revision(org, repo, tag)
  puts "revision #{org} #{repo} #{tag}"
  lines, status = sh 'git', 'ls-remote', '--quiet', '--tags', '--exit-code',
                     "https://github.com/#{org}/#{repo}", "refs/tags/#{tag}"
  return unless status.success?

  pp lines.each_line.first.split.first
end

def process_closure(flake_url)
  puts "closure #{flake_url}"

  return unless (out_path = nix_build(flake_url))
  return unless (content_addressed = nix_make_content_addressed(out_path))

  rewrites = JSON.parse(content_addressed).fetch('rewrites')

  raise "Encountered more than one rewrite object: #{rewrites.inspect}" if rewrites.size > 1

  from_path, to_path = rewrites.first
  { fromPath: from_path, toPath: to_path, fromStore: 'https://cache.iog.io' }
end

def nix_build(flake_url)
  out_path, status = sh 'nix', 'build', '--no-link', '--no-write-lock-file', '--print-out-paths', flake_url
  out_path.strip if status.success?
end

def nix_make_content_addressed(out_path)
  content_addressed, status =
    sh 'nix', 'store', 'make-content-addressed', out_path,
       '--json',
       '--from', 'https://cache.iog.io',
       '--to', "s3://devx?secret-key=#{KEY}&endpoint=#{ENDPOINT}&region=auto&compression=zstd"
  content_addressed if status.success?
end

def update_from_github_releases(store, org, repo, flake_urls)
  JSON.parse(File.read("releases/#{org}/#{repo}.json")).each do |tag, commit|
    flake_urls.each do |flake_url|
      SYSTEMS.each do |system|
        flake_url = flake_url.gsub('${tag}', tag).gsub('${system}', system)
        update_from_github_release(store, org, repo, flake_url, tag)
      end
    end
  end
end

def update_from_github_release(store, org, repo, flake_url, tag)
  store[flake_url] ||= {}
  puts "Processing #{flake_url}"
  process(store[flake_url], flake_url, org, repo, tag)
  File.write('packages.json', JSON.pretty_generate(store))
end

def update_from_git(store, org, repo, flake_urls)

end

# Output should look like this:
# {
#   "github:input-output-hk/cardano-node/8.2.1-pre#packages.x86_64-linux.bech32": {
#     tag: '8.2.1-pre',
#     rev: '',
#     name: 'bech32',
#     system: 'x86_64-linux',
#     repo: 'cardano-node',
#     org: 'input-output-hk',
#     meta: {},
#     closure: {
#       fromPath: '',
#       toPath: '',
#       fromStore: ''
#     }
#   }
# }

File.file?('packages.json') || File.write('packages.json', '{}')

store = JSON.parse(File.read('packages.json'))

JSON.parse(File.read('projects.json')).each do |org, repos|
  repos.each do |repo, repo_config|
    case repo_config.fetch('tags_from')
    when 'git'
      update_from_git(store, org, repo, repo_config.fetch('packages'))
    when 'github-releases'
      update_from_github_releases(store, org, repo, repo_config.fetch('packages'))
    end
  end
end
