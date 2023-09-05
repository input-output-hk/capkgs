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
      _ => { error make {msg: $"Invalid type: ($r.repo_config.type)"}}
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
          git ls-remote --exit-code --tags $"https://github.com/($org)/($repo)" $tag
          | from git ls-remote
          | where ref =~ $tag
          | first
        )
      }
      | refs-to-json
      | save -f $dst
    )
}

def fetch-git-tags [org: string, repo: string, dst: string, pattern: string] {
  let url = $"https://github.com/($org)/($repo)"
  print $"Fetching tags from ($url) ..."

  (
    git ls-remote --exit-code $url 'refs/tags/*'
    | from git ls-remote
    | where ref =~ $pattern
    | refs-to-json
    | save -f $dst
  )
}

def fetch-git-branches [org: string, repo: string, dst: string, branches: table] {
  let url = $"https://github.com/($org)/($repo)"
  print $"Fetching branches from ($url) ..."

  $branches | each {|branch|
    (
      git ls-remote --exit-code $url $"refs/heads/($branch)"
      | from git ls-remote
      | refs-to-json
      | save -f $dst
    )
  }
}

def refs-to-json [] {
  reduce -f {} {|value, sum|
    $sum | merge {($value.ref | str replace -r 'refs/(tags|heads)/' ''): $value.rev}
  } | to json
}

def "from git ls-remote" [] {
  from tsv --noheaders
  | rename rev ref
  | where ref =~ 'refs/(tags|heads)'
}

open projects.json | transpose org repos | fetch-orgs | to json