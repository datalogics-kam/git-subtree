#!/bin/bash
#
# git-subtree.sh: split/join git repositories in subdirectories of this one
#
# Copyright (C) 2009 Avery Pennarun <apenwarr@gmail.com>
#
if [ $# -eq 0 ]; then
    set -- -h
fi
OPTS_SPEC="\
git subtree add   --prefix=<prefix> <repository> <refspec>
git subtree merge --prefix=<prefix> <commit>
git subtree pull  --prefix=<prefix> [<repository> [<refspec>...]]
git subtree pull-all
git subtree push-all
git subtree push  --prefix=<prefix> [<repository> [<refspec>...]]
git subtree list
git subtree split --prefix=<prefix> <commit...>
git subtree from-submodule --prefix=<prefix>
git subtree prune
git subtree diff  --prefix=<prefix> [<repository> [<refspec>...]]
--
h,help        show the help
q             quiet
d             show debug messages
P,prefix=     the name of the subdir to split out
m,message=    use the given message as the commit message for the merge commit
 options for 'split'
annotate=     add a prefix to commit message of new commits
b,branch=     create a new branch from the split subtree
ignore-joins  ignore prior --rejoin commits
onto=         try connecting new tree to an existing one
rejoin        merge the new branch back into HEAD
 options for 'push'
f,force	      use force push
 options for 'add', 'merge', 'pull' and 'push'
squash        merge subtree changes as a single commit
"
eval "$(echo "$OPTS_SPEC" | git rev-parse --parseopt -- "$@" || echo exit $?)"

PATH=$PATH:$(git --exec-path)
. git-sh-setup

require_work_tree

quiet=
branch=
debug=
command=
onto=
rejoin=
ignore_joins=
annotate=
squash=
message=

debug()
{
	if [ -n "$debug" ]; then
		echo "$@" >&2
	fi
}

say()
{
	if [ -z "$quiet" ]; then
		echo "$@" >&2
	fi
}

assert()
{
	if "$@"; then
		:
	else
		die "assertion failed: " "$@"
	fi
}


#echo "Options: $*"

while [ $# -gt 0 ]; do
	opt="$1"
	shift
	case "$opt" in
		-q) quiet=1 ;;
		-d) debug=1 ;;
		--annotate) annotate="$1"; shift ;;
		--no-annotate) annotate= ;;
		-b) branch="$1"; shift ;;
		-P|--prefix) prefix="$1"; shift ;;
		-m) message="$1"; shift ;;
		-f|--force) force=1 ;;
		--no-prefix) prefix= ;;
		--onto) onto="$1"; shift ;;
		--no-onto) onto= ;;
		--rejoin) rejoin=1 ;;
		--no-rejoin) rejoin= ;;
		--ignore-joins) ignore_joins=1 ;;
		--no-ignore-joins) ignore_joins= ;;
		--squash) squash=1 ;;
		--no-squash) squash= ;;
		--) break ;;
		*) die "Unexpected option: $opt" ;;
	esac
done

# Remove trailing slash
prefix="${prefix%/}";

command="$1"
shift
case "$command" in
	add|merge|pull|pull-all|push-all|from-submodule|prune) default= ;;
	split|push|diff|list) default="--default HEAD" ;;
	*) die "Unknown command '$command'" ;;
esac

if [ -z "$prefix" -a "$command" != "pull-all" -a "$command" != "push-all" -a "$command" != "list" -a "$command" != "prune" ]; then
	die "You must provide the --prefix option."
fi

case "$command" in
	pull-all);;
	push-all);;
	list);;
	prune);;
	add) [ -e "$prefix" ] && 
		die "prefix '$prefix' already exists." ;;
	*)   [ -e "$prefix" ] || 
		die "'$prefix' does not exist; use 'git subtree add'" ;;
esac

dir="$(dirname "$prefix/.")"

if [ "$command" != "pull" -a "$command" != "add" -a "$command" != "push" -a "$command" != "pull-all" -a "$command" != "diff" ]; then
	revs=$(git rev-parse $default --revs-only "$@") || exit $?
	dirs="$(git rev-parse --no-revs --no-flags "$@")" || exit $?
	if [ -n "$dirs" ]; then
		die "Error: Use --prefix instead of bare filenames."
	fi
fi

debug "command: {$command}"
debug "quiet: {$quiet}"
debug "revs: {$revs}"
debug "dir: {$dir}"
debug "opts: {$*}"
debug

cache_setup()
{
	cachedir="$GIT_DIR/subtree-cache/$$"
	rm -rf "$cachedir" || die "Can't delete old cachedir: $cachedir"
	mkdir -p "$cachedir" || die "Can't create new cachedir: $cachedir"
	mkdir -p "$cachedir/notree" || die "Can't create new cachedir: $cachedir/notree"
	debug "Using cachedir: $cachedir" >&2
}

cache_get()
{
	for oldrev in $*; do
		if [ -r "$cachedir/$oldrev" ]; then
			read newrev <"$cachedir/$oldrev"
			echo $newrev
		fi
	done
}

cache_miss()
{
	for oldrev in $*; do
		if [ ! -r "$cachedir/$oldrev" ]; then
			echo $oldrev
		fi
	done
}

check_parents()
{
	missed=$(cache_miss $*)
	for miss in $missed; do
		if [ ! -r "$cachedir/notree/$miss" ]; then
			debug "  incorrect order: $miss"
		fi
	done
}

set_notree()
{
	echo "1" > "$cachedir/notree/$1"
}

cache_set()
{
	oldrev="$1"
	newrev="$2"
	if [ "$oldrev" != "latest_old" \
	     -a "$oldrev" != "latest_new" \
	     -a -e "$cachedir/$oldrev" ]; then
		die "cache for $oldrev already exists!"
	fi
	echo "$newrev" >"$cachedir/$oldrev"
}

rev_exists()
{
	if git rev-parse "$1" >/dev/null 2>&1; then
		return 0
	else
		return 1
	fi
}

rev_is_descendant_of_branch()
{
	newrev="$1"
	branch="$2"
	branch_hash=$(git rev-parse $branch)
	match=$(git rev-list -1 $branch_hash ^$newrev)

	if [ -z "$match" ]; then
		return 0
	else
		return 1
	fi
}

# if a commit doesn't have a parent, this might not work.  But we only want
# to remove the parent from the rev-list, and since it doesn't exist, it won't
# be there anyway, so do nothing in that case.
try_remove_previous()
{
	if rev_exists "$1^"; then
		echo "^$1^"
	fi
}

find_latest_squash()
{
	debug "Looking for latest squash ($dir)..."
	dir="$1"
	sq=
	main=
	sub=
	git log --grep="^git-subtree-dir: $dir/*\$" \
		--pretty=format:'START %H%n%s%n%n%b%nEND%n' HEAD |
	while read a b junk; do
		debug "$a $b $junk"
		debug "{{$sq/$main/$sub}}"
		case "$a" in
			START) sq="$b" ;;
			git-subtree-mainline:) main="$b" ;;
			git-subtree-split:) sub="$b" ;;
			END)
				if [ -n "$sub" ]; then
					if [ -n "$main" ]; then
						# a rejoin commit?
						# Pretend its sub was a squash.
						sq="$sub"
					fi
					debug "Squash found: $sq $sub"
					echo "$sq" "$sub"
					break
				fi
				sq=
				main=
				sub=
				;;
		esac
	done
}

find_existing_splits()
{
	debug "Looking for prior splits..."
	dir="$1"
	revs="$2"
	main=
	sub=
	git log --grep="^git-subtree-dir: $dir/*\$" \
		--pretty=format:'START %H%n%s%n%n%b%nEND%n' $revs |
	while read a b junk; do
		case "$a" in
			START) sq="$b" ;;
			git-subtree-mainline:) main="$b" ;;
			git-subtree-split:) sub="$b" ;;
			END)
				debug "  Main is: '$main'"
				if [ -z "$main" -a -n "$sub" ]; then
					# squash commits refer to a subtree
					debug "  Squash: $sq from $sub"
					cache_set "$sq" "$sub"
				fi
				if [ -n "$main" -a -n "$sub" ]; then
					debug "  Prior: $main -> $sub"
					cache_set $main $sub
					cache_set $sub $sub
					try_remove_previous "$main"
					try_remove_previous "$sub"
				fi
				main=
				sub=
				;;
		esac
	done
}

copy_commit()
{
	# We're going to set some environment vars here, so
	# do it in a subshell to get rid of them safely later
	debug copy_commit "{$1}" "{$2}" "{$3}"
	git log -1 --pretty=format:'%an%n%ae%n%ad%n%cn%n%ce%n%cd%n%s%n%n%b' "$1" |
	(
		read GIT_AUTHOR_NAME
		read GIT_AUTHOR_EMAIL
		read GIT_AUTHOR_DATE
		read GIT_COMMITTER_NAME
		read GIT_COMMITTER_EMAIL
		read GIT_COMMITTER_DATE
		export  GIT_AUTHOR_NAME \
			GIT_AUTHOR_EMAIL \
			GIT_AUTHOR_DATE \
			GIT_COMMITTER_NAME \
			GIT_COMMITTER_EMAIL \
			GIT_COMMITTER_DATE
		(echo -n "$annotate"; cat ) |
		git commit-tree "$2" $3  # reads the rest of stdin
	) || die "Can't copy commit $1"
}

add_msg()
{
	dir="$1"
	latest_old="$2"
	latest_new="$3"
	if [ -n "$message" ]; then
		commit_message="$message"
	else
		commit_message="Add '$dir/' from commit '$latest_new'"
	fi
	cat <<-EOF
		$commit_message
		
		git-subtree-dir: $dir
		git-subtree-mainline: $latest_old
		git-subtree-split: $latest_new
	EOF
}

add_squashed_msg()
{
	if [ -n "$message" ]; then
		echo "$message"
	else
		echo "Merge commit '$1' as '$2'"
	fi
}

rejoin_msg()
{
	dir="$1"
	latest_old="$2"
	latest_new="$3"
	if [ -n "$message" ]; then
		commit_message="$message"
	else
		commit_message="Split '$dir/' into commit '$latest_new'"
	fi
	cat <<-EOF
		$commit_message
		
		git-subtree-dir: $dir
		git-subtree-mainline: $latest_old
		git-subtree-split: $latest_new
	EOF
}

squash_msg()
{
	dir="$1"
	oldsub="$2"
	newsub="$3"
	newsub_short=$(git rev-parse --short "$newsub")
	
	if [ -n "$oldsub" ]; then
		oldsub_short=$(git rev-parse --short "$oldsub")
		echo "Squashed '$dir/' changes from $oldsub_short..$newsub_short"
		echo
		git log --pretty=tformat:'%h %s' "$oldsub..$newsub"
		git log --pretty=tformat:'REVERT: %h %s' "$newsub..$oldsub"
	else
		echo "Squashed '$dir/' content from commit $newsub_short"
	fi
	
	echo
	echo "git-subtree-dir: $dir"
	echo "git-subtree-split: $newsub"
}

toptree_for_commit()
{
	commit="$1"
	git log -1 --pretty=format:'%T' "$commit" -- || exit $?
}

subtree_for_commit()
{
	commit="$1"
	dir="$2"
	git ls-tree "$commit" -- "$dir" |
	while read mode type tree name; do
		assert [ "$name" = "$dir" ]
		assert [ "$type" = "tree" -o "$type" = "commit" ]
		[ "$type" = "commit" ] && continue  # ignore submodules
		echo $tree
		break
	done
}

tree_changed()
{
	tree=$1
	shift
	if [ $# -ne 1 ]; then
		return 0   # weird parents, consider it changed
	else
		ptree=$(toptree_for_commit $1)
		if [ "$ptree" != "$tree" ]; then
			return 0   # changed
		else
			return 1   # not changed
		fi
	fi
}

new_squash_commit()
{
	old="$1"
	oldsub="$2"
	newsub="$3"
	tree=$(toptree_for_commit $newsub) || exit $?
	if [ -n "$old" ]; then
		squash_msg "$dir" "$oldsub" "$newsub" | 
			git commit-tree "$tree" -p "$old" || exit $?
	else
		squash_msg "$dir" "" "$newsub" |
			git commit-tree "$tree" || exit $?
	fi
}

copy_or_skip()
{
	rev="$1"
	tree="$2"
	newparents="$3"
	assert [ -n "$tree" ]

	identical=
	nonidentical=
	p=
	gotparents=
	for parent in $newparents; do
		ptree=$(toptree_for_commit $parent) || exit $?
		[ -z "$ptree" ] && continue
		if [ "$ptree" = "$tree" ]; then
			# an identical parent could be used in place of this rev.
			identical="$parent"
		else
			nonidentical="$parent"
		fi
		
		# sometimes both old parents map to the same newparent;
		# eliminate duplicates
		is_new=1
		for gp in $gotparents; do
			if [ "$gp" = "$parent" ]; then
				is_new=
				break
			fi
		done
		if [ -n "$is_new" ]; then
			gotparents="$gotparents $parent"
			p="$p -p $parent"
		fi
	done
	
	if [ -n "$identical" ]; then
		echo $identical
	else
		copy_commit $rev $tree "$p" || exit $?
	fi
}

ensure_clean()
{
	if ! git diff-index HEAD --exit-code --quiet 2>&1; then
		die "Working tree has modifications.  Cannot add."
	fi
	if ! git diff-index --cached HEAD --exit-code --quiet 2>&1; then
		die "Index has modifications.  Cannot add."
	fi
}

cmd_add()
{
	if [ -e "$dir" ]; then
		die "'$dir' already exists.  Cannot add."
	fi

	ensure_clean
	
	if [ $# -eq 1 ]; then
		"cmd_add_commit" "$@"
	elif [ $# -eq 2 ]; then
		"cmd_add_repository" "$@"
	else
	    say "error: parameters were '$@'"
	    die "Provide either a refspec or a repository and refspec."
	fi
}

cmd_add_repository()
{
	echo "git fetch" "$@"
	repository=$1
	refspec=$2
	git fetch "$@" || exit $?
	revs=FETCH_HEAD
	set -- $revs
	cmd_add_commit "$@"

	# now add it to our list of repos 
	git config -f .gittrees --unset subtree.$dir.url
	git config -f .gittrees --add subtree.$dir.url $repository
	git config -f .gittrees --unset subtree.$dir.path
	git config -f .gittrees --add subtree.$dir.path $dir
	git config -f .gittrees --unset subtree.$dir.branch
	git config -f .gittrees --add subtree.$dir.branch $refspec
}

cmd_add_commit()
{
	revs=$(git rev-parse $default --revs-only "$@") || exit $?
	set -- $revs
	rev="$1"
	
	debug "Adding $dir as '$rev'..."
	git read-tree --prefix="$dir" $rev || exit $?
	git checkout -- "$dir" || exit $?
	tree=$(git write-tree) || exit $?
	
	headrev=$(git rev-parse HEAD) || exit $?
	if [ -n "$headrev" -a "$headrev" != "$rev" ]; then
		headp="-p $headrev"
	else
		headp=
	fi
	
	if [ -n "$squash" ]; then
		rev=$(new_squash_commit "" "" "$rev") || exit $?
		commit=$(add_squashed_msg "$rev" "$dir" |
			 git commit-tree $tree $headp -p "$rev") || exit $?
	else
		commit=$(add_msg "$dir" "$headrev" "$rev" |
			 git commit-tree $tree $headp -p "$rev") || exit $?
	fi
	git reset "$commit" || exit $?
	
	say "Added dir '$dir'"
}

cmd_split()
{
	debug "Splitting $dir..."
	cache_setup || exit $?
	
	if [ -n "$onto" ]; then
		debug "Reading history for --onto=$onto..."
		git rev-list $onto |
		while read rev; do
			# the 'onto' history is already just the subdir, so
			# any parent we find there can be used verbatim
			debug "  cache: $rev"
			cache_set $rev $rev
		done
	fi
	
	if [ -n "$ignore_joins" ]; then
		unrevs=
	else
		unrevs="$(find_existing_splits "$dir" "$revs")"
	fi
	
	# We can't restrict rev-list to only $dir here, because some of our
	# parents have the $dir contents the root, and those won't match.
	# (and rev-list --follow doesn't seem to solve this)
	grl='git rev-list --topo-order --reverse --parents $revs $unrevs'
	revmax=$(eval "$grl" | wc -l)
	revcount=0
	createcount=0
	eval "$grl" |
	while read rev parents; do
		revcount=$(($revcount + 1))
		say -n "$revcount/$revmax ($createcount)
"
		debug "Processing commit: $rev"
		exists=$(cache_get $rev)
		if [ -n "$exists" ]; then
			debug "  prior: $exists"
			continue
		fi
		createcount=$(($createcount + 1))
		debug "  parents: $parents"
		newparents=$(cache_get $parents)
		debug "  newparents: $newparents"
		
		tree=$(subtree_for_commit $rev "$dir")
		debug "  tree is: $tree"

		check_parents $parents
		
		# ugly.  is there no better way to tell if this is a subtree
		# vs. a mainline commit?  Does it matter?
		if [ -z $tree ]; then
			set_notree $rev
			if [ -n "$newparents" ]; then
				cache_set $rev $rev
			fi
			continue
		fi

		newrev=$(copy_or_skip "$rev" "$tree" "$newparents") || exit $?
		debug "  newrev is: $newrev"
		cache_set $rev $newrev
		cache_set latest_new $newrev
		cache_set latest_old $rev
	done || exit $?
	latest_new=$(cache_get latest_new)
	if [ -z "$latest_new" ]; then
		die "No new revisions were found"
	fi
	
	if [ -n "$rejoin" ]; then
		debug "Merging split branch into HEAD..."
		latest_old=$(cache_get latest_old)
		git merge -s ours \
			-m "$(rejoin_msg $dir $latest_old $latest_new)" \
			$latest_new >&2 || exit $?
	fi
	if [ -n "$branch" ]; then
		if rev_exists "refs/heads/$branch"; then
			if ! rev_is_descendant_of_branch $latest_new $branch; then
				die "Branch '$branch' is not an ancestor of commit '$latest_new'."
			fi
			action='Updated'
		else
			action='Created'
		fi
		git update-ref -m 'subtree split' "refs/heads/$branch" $latest_new || exit $?
		say "$action branch '$branch'"
	fi
	echo $latest_new
	exit 0
}

cmd_merge()
{
	revs=$(git rev-parse $default --revs-only "$@") || exit $?
	ensure_clean
	
	set -- $revs
	if [ $# -ne 1 ]; then
		die "You must provide exactly one revision.  Got: '$revs'"
	fi
	rev="$1"
	
	if [ -n "$squash" ]; then
		first_split="$(find_latest_squash "$dir")"
		if [ -z "$first_split" ]; then
			die "Can't squash-merge: '$dir' was never added."
		fi
		set $first_split
		old=$1
		sub=$2
		if [ "$sub" = "$rev" ]; then
			say "Subtree is already at commit $rev."
			exit 0
		fi
		new=$(new_squash_commit "$old" "$sub" "$rev") || exit $?
		debug "New squash commit: $new"
		rev="$new"
	fi

	version=$(git version)
	if [ "$version" \< "git version 1.7" ]; then
		if [ -n "$message" ]; then
			git merge -s subtree --message="$message" $rev
		else
			git merge -s subtree $rev
		fi
	else
		if [ -n "$message" ]; then
			git merge -Xsubtree="$prefix" --message="$message" $rev
		else
			git merge -Xsubtree="$prefix" $rev
		fi
	fi
}

cmd_pull()
{
	if [ $# -gt 2 ]; then
		die "You should provide either <refspec> or <repository> <refspec>"
	fi
	if [ -e "$dir" ]; then
		ensure_clean
		if [ $# -eq 1 ]; then 
			repository=$(git config -f .gittrees subtree.$prefix.url)
			refspec=$1
		elif [ $# -eq 2 ]; then 
			repository=$1
			refspec=$2
		else 
			repository=$(git config -f .gittrees subtree.$prefix.url)
			refspec=$(git config -f .gittrees subtree.$prefix.branch)
		fi
		git fetch $repository $refspec || exit $?
		echo "git fetch using: " $repository $refspec
		revs=FETCH_HEAD
		set -- $revs
		cmd_merge "$@"
	else
		die "'$dir' must already exist. Try 'git subtree add'."
	fi
}

cmd_diff() 
{
	if [ -e "$dir" ]; then
		if [ $# -eq 1 ]; then 
			repository=$(git config -f .gittrees subtree.$prefix.url)
			refspec=$1
		elif [ $# -eq 2 ]; then 
			repository=$1
			refspec=$2
		else
			repository=$(git config -f .gittrees subtree.$prefix.url)
			refspec=$(git config -f .gittrees subtree.$prefix.branch)
		fi
		# this is ugly, but I don't know of a better way to do it. My git-fu is weak. 
		# git diff-tree expects a treeish, but I have only a repository and branch name.
		# I don't know how to turn that into a treeish without creating a remote.
		# Please change this if you know a better way! 
		tmp_remote=__diff-tmp
		git remote rm $tmp_remote > /dev/null 2>&1
		git remote add -t $refspec $tmp_remote $repository > /dev/null
		# we fetch as a separate step so we can pass -q (quiet), which isn't an option for "git remote"
		# could this instead be "git fetch -q $repository $refspec" and leave aside creating the remote?
		# Still need a treeish for the diff-tree command...
		git fetch -q $tmp_remote 
		git diff-tree -p refs/remotes/$tmp_remote/$refspec
		git remote rm $tmp_remote > /dev/null 2>&1
	else 
		die "Cannot resolve directory '$dir'. Please point to an existing subtree directory to diff. Try 'git subtree add' to add a subtree."
	fi
}
cmd_push()
{
	if [ $# -gt 2 ]; then
		die "You shold provide either <refspec> or <repository> <refspec>"
	fi
	if [ -e "$dir" ]; then
		if [ $# -eq 1 ]; then 
			repository=$(git config -f .gittrees subtree.$prefix.url)
			refspec=$1
		elif [ $# -eq 2 ]; then 
			repository=$1
			refspec=$2
		else
			repository=$(git config -f .gittrees subtree.$prefix.url)
			refspec=$(git config -f .gittrees subtree.$prefix.branch)
		fi

		push_opts=
		if [ "$force" == "1" ]; then
		  push_opts="$push_opts --force"
		fi

		echo "git push using: " $repository $refspec
		rev=$(git subtree split --prefix=$prefix)
		if [ -n "$rev" ]; then
			git push $push_opts $repository $rev:refs/heads/$refspec
		else
			die "Couldn't push, 'git subtree split' failed."
		fi
	else
	    die "'$dir' must already exist. Try 'git subtree add'."
	fi
}

subtree_list() 
{
	git config -f .gittrees -l | grep subtree | grep path | grep -o '=.*' | grep -o '[^=].*' |
	while read path; do 
		repository=$(git config -f .gittrees subtree.$path.url)
		refspec=$(git config -f .gittrees subtree.$path.branch)
		echo "	$path		(merged from $repository branch $refspec) "
	done
}

cmd_list()
{
  subtree_list 
}

cmd_from-submodule()
{
	ensure_clean

	local submodule_sha=$(git submodule status $prefix | cut -d ' ' -f 2)
	local submodule_orig_repo=$(git config --file .gitmodules submodule.$prefix.url)

	# Remove references to submodule.
	git config --remove-section submodule.$prefix
	git config --file .gitmodules --remove-section submodule.$prefix
	git add .gitmodules

	# Move submodule aside.
	local tmp_repo="$(mktemp -d /tmp/git-subtree.XXXXX)"
	rm -r $tmp_repo
	if [ -f $prefix/.git ]
	then
		# Have to unset core.worktree or this will suffer
		(cd $prefix && git config --unset core.worktree)

		# Handle new git submodules stored in parent repo
		local actual_git=$(sed -e 's/^gitdir: //' $prefix/.git)
		local tmp_git="$(mktemp -d /tmp/git-subtree.XXXXX)"
		mv $prefix/$actual_git $tmp_git/.git
		mv $prefix $tmp_repo
		rm $tmp_repo/.git
		mv $tmp_git/.git $tmp_repo/.git
		rm -rf $tmp_git
	else
		mv $prefix $tmp_repo
	fi
	git rm $prefix

	# Commit changes.
	git commit -m "Remove '$prefix/' submodule"

	# subtree add from submodule repo.
	# TODO: Could be determin HEAD to be a specific branch
	cmd_add_repository $tmp_repo HEAD

	# Update .gittrees with the original repo url
	git config --file .gittrees --unset subtree.$prefix.url
	git config --file .gittrees subtree.$prefix.url $submodule_orig_repo

	# Remove submodule repo.
	rm -rf $tmp_repo
}

cmd_prune()
{
	git config -f .gittrees -l | grep subtree | grep path | grep -o '=.*' | grep -o '[^=].*' |
	while read path; do
		if [ ! -e "$path" ]; then
			echo "pruning $path"
			git config -f .gittrees --remove-section subtree.$path
		fi
	done
}

cmd_pull-all()
{
	git config -f .gittrees -l | grep subtree | grep path | grep -o '=.*' | grep -o '[^=].*' |
	while read path; do
		git subtree pull -P $path $(git config -f .gittrees subtree.$path.url) $(git config -f .gittrees subtree.$path.branch) || exit $?
	done
}

cmd_push-all()
{
	git config -f .gittrees -l | grep subtree | grep path | grep -o '=.*' | grep -o '[^=].*' |
	while read path; do
		git subtree push -P $path $(git config -f .gittrees subtree.$path.url) $(git config -f .gittrees subtree.$path.branch) || exit $?
	done
}

"cmd_$command" "$@"
