help:
  just -l

# Iterate projects and fetch the release data from GitHub:
releases:
  #!/usr/bin/env nu

  let orgs = (open projects.json | transpose org repos)

  $orgs | each {|o|
    $o.repos | transpose repo attrs | each {|r|
      let dir = $"releases/($o.org)"

      match $r.tags_from {
      "git" => {
      },
      "github-releases" => {
      }
      let url = $"https://api.github.com/repos/($o.org)/($r.repo)/releases"
      mkdir $dir
      print $"Fetching releases for ($r.repo) from ($url) ..."

      (
        curl --fail-with-body $url
        | from json
        | each {|release| $release | select tag_name }
        | values
        | flatten
        | to json
        | save -f $"($dir)/($r.repo).json"
      )
    }
  }
