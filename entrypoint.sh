#!/bin/bash

set -o pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-true}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-true}
desired_minor=${DESIRED_MINOR:-[0-9]*}

cd ${GITHUB_WORKSPACE}/${source}

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"

setOutput() {
    echo "${1}=${2}" >> "${GITHUB_OUTPUT}"
}

current_branch=$(git rev-parse --abbrev-ref HEAD)

if [[ $current_branch =~ ^sprint_([0-9]+)$ ]]; then
  sprint_num=${BASH_REMATCH[1]}
  echo -e "This is a sprint ${sprint_num} branch"
  desired_minor=$sprint_num
fi
echo -e "\tDESIRED_MINOR: ${desired_minor}"

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    echo "Is $b a match for ${current_branch}"
    if [[ "${current_branch}" =~ $b ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags

# get latest tag that looks like a semver (with or without v)
case "$tag_context" in
    *repo*)
        tag=$(git for-each-ref --sort=-v:refname --format '%(refname)' | cut -d / -f 3- | grep -E "^v?[0-9]+.$desired_minor.[0-9]+.*$" | head -n1)
        pre_tag=$(git for-each-ref --sort=-v:refname --format '%(refname)' | cut -d / -f 3- | grep -E "^v?[0-9]+.$desired_minor.[0-9]+(-$suffix)?(.[0-9a-z]+)?$" | head -n1)
        ;;
    *branch*)
        tag=$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^v?[0-9]+.$desired_minor.[0-9]+.*$" | head -n1)
        pre_tag=$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^v?[0-9]+.$desired_minor.[0-9]+(-$suffix)?(.[0-9a-z]+)?$" | head -n1)
        ;;
    * ) echo "Unrecognised context"; exit 1;;
esac

# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$initial_version"
    pre_tag="$initial_version"
else
    log=$(git log $tag..HEAD --pretty='%B')
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 $tag)

# get current commit hash
commit=$(git rev-parse HEAD)

echo -e "\ttag: ${tag}\n\tpre_tag: ${pre_tag}"
echo -e "tag_commit: ${tag_commit}. \n\tcommit: ${commit}"

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    setOutput "tag" "$tag"
    setOutput "same-tag" "true"
    exit 0
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

clear_tag=`echo $tag | cut -d'-' -f 1`
case "$log" in
    *#major* ) new=$(semver -i major $clear_tag); part="major";;
    *#minor* ) new=$(semver -i minor $clear_tag); part="minor";;
    *#patch* ) new=$(semver -i patch $clear_tag); part="patch";;
    * )
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Skipping..."; exit 0
        else
            new=$(semver -i "${default_semvar_bump}" $clear_tag); part=$default_semvar_bump
        fi
        ;;
esac

if $pre_release
then
    # Already a prerelease available, bump it
    if [[ "$pre_tag" == *"$new"* ]]; then
        new=$(semver -i prerelease $pre_tag --preid $suffix); part="pre-$part"
    else
        new="$new-${commit:0:7}"; part="pre-$part"
    fi
fi

echo $part

# did we get a new tag?
if [ ! -z "$new" ]
then
	# prefix with 'v'
	if $with_v
	then
		new="v$new"
	fi
fi

if [ ! -z $custom_tag ]
then
    new="$custom_tag"
fi

if $pre_release
then
    echo -e "Bumping tag ${pre_tag}. \n\tNew tag ${new}"
else
    echo -e "Bumping tag ${tag}. \n\tNew tag ${new}"
fi

# set outputs
echo  "commits=log=$log"
setOutput "commits" "$log"
echo "new_tag=new=$new"
setOutput "new_tag" "$new"
echo "part=part=$part"
setOutput "part" "$part"
echo "same-tag=false"
setOutput "same-tag" "false"

# use dry run to determine the next tag
if $dryrun
then
    echo "tag=tag=$tag"
    tag=$(echo $tag | tr '\n' ' ')
    setOutput "tag" "$tag"
    echo "tag=tag->end"
    exit 0
fi

echo "tag=new=$new"
tag=$(echo $tag | tr '\n' ' ')
setOutput "tag" "$new"
echo "tag=new->end"

# create local git tag
git tag $new

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new to repo $full_name"

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF
{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
