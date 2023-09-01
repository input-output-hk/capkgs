#!/usr/bin/env nu

def fetch-orgs [] {
  each {|o| $o.repos | transpose repo repo_config | fetch-repo $o.org }
}

def fetch-repo [org: string] {
  each {|r|
    let dst = $"releases/($org)/($r.repo).json"
    mkdir ($dst | path dirname)

    match $r.repo_config.type {
      git_branches    => { fetch-git-branches    $org $r.repo $dst $r.repo_config.branches },
      git_tags        => { fetch-git-tags        $org $r.repo $dst $r.repo_config.pattern },
      github_releases => { fetch-github-releases $org $r.repo $dst }
    }
  }
}

def fetch-github-releases [org: string, repo: string, dst: string] {
    let url = $"https://api.github.com/repos/($org)/($repo)/releases"
    print $"Fetching releases from ($url) ..."

    (
      curl -s --fail-with-body $url
      | from json
      | each {|release| $release | select tag_name }
      | values
      | flatten
      | each {|tag|
        (
          git-ls-remote --tags $"https://github.com/($org)/($repo)" $tag
          | from tsv --noheaders
          | rename commit tag 
          | where tag =~ $tag
          | first
        )
      }
      | reduce -f {} {|v,s| $s | merge {($v.tag | rename-ref): $v.commit} }
      | to json
      | save -f $dst
    )
}

def fetch-git-tags [org: string, repo: string, dst: string, pattern: string] {
  let url = $"https://github.com/($org)/($repo)"
  print $"Fetching tags from ($url) ..."

  (
    git-ls-remote $url
    | rename commit tag 
    | where tag =~ $pattern
    | each {|e| {($e.tag | rename-ref): $e.commit}}
    | reduce {|s,v| $s | merge $v }
    | to json
    | save -f $dst
  )
}

def fetch-git-branches [org: string, repo: string, dst: string, branches: table] {
  let url = $"https://github.com/($org)/($repo)"
  print $"Fetching branches from ($url) ..."

  $branches | each {|branch|
    (
      git-ls-remote $url $branch
      | first
      | rename commit tag 
      | each {|e| {($e.tag | rename-ref): $e.commit}}
      | reduce {|s,v| $s | merge $v }
      | to json
      | save -f $dst
    )
  }
}

def rename-ref [] {
  str replace 'refs/(tags|heads)/' ''
}

def "git ls-remote" [...args: string] { ^git ls-remote $args | from tsv --noheaders | rename rev ref }

open projects.json | transpose org repos | fetch-orgs | to json