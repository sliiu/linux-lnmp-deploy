# shellcheck shell=bash
# ═══════════════════════════════════════════════
#  saferm（合并自 saferm.sh，安装到 /usr/local/bin/saferm）
# ═══════════════════════════════════════════════
_install_saferm_rm_alias() {
  mkdir -p /etc/profile.d
  cat > /etc/profile.d/saferm-rm.sh <<'EOF'
# init.sh: 交互 shell 中 rm -> saferm
alias rm='/usr/local/bin/saferm'
EOF
  chmod 644 /etc/profile.d/saferm-rm.sh
  local f
  for f in /etc/bash.bashrc /etc/bashrc /etc/zshrc; do
    [[ -f "$f" ]] || continue
    grep -qF 'saferm init.sh' "$f" && continue
    cat >> "$f" <<'EOF'

# >>> saferm init.sh >>>
[ -f /etc/profile.d/saferm-rm.sh ] && . /etc/profile.d/saferm-rm.sh
# <<< saferm init.sh <<<
EOF
  done
}

# 安装 saferm 后在本 bash 进程内启用 rm 别名（须配合全脚本使用 /bin/rm，避免误走 saferm）
_saferm_apply_to_current_shell() {
  [[ -f /etc/profile.d/saferm-rm.sh ]] || return 0
  shopt -s expand_aliases 2>/dev/null || true
  # shellcheck disable=SC1091
  source /etc/profile.d/saferm-rm.sh
}

_saferm_drop_current_shell_alias() {
  unalias rm 2>/dev/null || true
  shopt -u expand_aliases 2>/dev/null || true
}

install_saferm() {
  hr; info "安装 saferm（/var/trash 安全删除 + 全局 rm 别名）"; echo ""
  cat > /usr/local/bin/saferm <<'SAFEEOF'
#!/bin/bash
##
## saferm.sh
## A script to safely remove files by moving them to GNOME/KDE trash instead of direct deletion.
## Created by Lucas Zhang
## Contact: <lucas@qing-u.com>
##
## Created on  Mon Feb 17 10:10:18 2025 Lucas Zhang
## Last modified Mon Feb 17 12:49:26 2025 Lucas Zhang
##
## Original author: Eemil Lagerspetz
##

version="1.1"

## Configuration
cleanup_days=60     # Remove files from trash after specified days (0 to disable)
auto_cleanup=""     # Enable automatic cleanup on each run (empty to disable)
max_trash_size=1024 # Maximum trash size in MB (0 for unlimited)

## trashbin definitions
trash_dir="/var/trash"

## flags (change these to change default behaviour)
recursive=""    # Recursive directory deletion (disabled by default)
verbose="true"  # Verbose output for better user experience
force=""        # Special file deletion protection (disabled by default)
unsafe=""       # Safe deletion mode by default
no_log=""       # Enable logging by default
cleanup_only="" # Normal operation mode by default

## possible flags (recursive, verbose, force, unsafe)
# don't touch this unless you want to create/destroy flags
flaglist="r v f u q n c"

# Colors
blue='\e[1;34m'
red='\e[1;31m'
norm='\e[0m'

trash_dev() { stat -c '%d' "$1" 2>/dev/null || echo ""; }

if [ ! -d "${trash_dir}" ]; then
	sudo mkdir -p "${trash_dir}"
	sudo chmod 1777 "${trash_dir}"
fi
if [ ! -d "${trash_dir}/files" ]; then
	sudo mkdir -p "${trash_dir}/files"
	sudo chmod 1777 "${trash_dir}/files"
fi
if [ ! -d "${trash_dir}/logs" ]; then
	sudo mkdir -p "${trash_dir}/logs"
	sudo chmod 1777 "${trash_dir}/logs"
fi
trash="${trash_dir}/files"


usagemessage() {
	echo -e "This is ${blue}saferm.sh$norm $version with LXDE and Gnome3 detection.
    Features:
    - Prompts for unsafe deletion when cross-filesystem moves are required
    - Supports unsafe deletion mode (regular rm) that bypasses trash
    - Automatically creates trash and trashinfo directories if they don't exist
    - Handles symbolic link deletion
    - Improved user permission handling\n"
	echo -e "Usage: ${blue}/path/to/saferm.sh$norm [${blue}OPTIONS$norm] [$blue--$norm] ${blue}files and directories to remove safely$norm"
	echo -e "${blue}OPTIONS$norm:"
	echo -e "$blue-r$norm      Enable recursive directory removal"
	echo -e "$blue-f$norm      Enable deletion of special files (devices, etc.)"
	echo -e "$blue-u$norm      Enable unsafe mode (bypass trash and delete permanently)"
	echo -e "$blue-v$norm      Enable verbose mode (default in this version)"
	echo -e "$blue-q$norm      Enable quiet mode (opposite of verbose)"
	echo -e "$blue-n$norm      Disable logging to trashinfo"
	echo -e "$blue-a$norm      Enable automatic trash cleanup"
	echo -e "$blue-c$norm      Run trash cleanup only (no file deletion)"
}

trashinfo() {
	bname=$(basename -- "$2")
	fname="${trash_dir}/logs/${bname}.trashinfo"
	cat <<EOF >"${fname}"
[Trash Info]
Path=$1
DeletionDate=$(date +%Y-%m-%dT%H:%M:%S)
EOF
}

setflags() {
	flags_set=""
	for k in $flaglist; do
		if [[ "$1" =~ $k ]]; then
			flags_set="$flags_set $k"
		fi
	done

	for k in $flags_set; do
		if [ "$k" == "v" ]; then
			verbose="true"
		elif [ "$k" == "r" ]; then
			recursive="true"
		elif [ "$k" == "f" ]; then
			force="true"
		elif [ "$k" == "u" ]; then
			unsafe="true"
		elif [ "$k" == "q" ]; then
			unset verbose
		elif [ "$k" == "n" ]; then
			no_log="true"
		elif [ "$k" == "c" ]; then
			cleanup_only="true"
			auto_cleanup="true"
		elif [ "$k" == "a" ]; then
			auto_cleanup="true"
		fi
	done
}

performdelete() {
	# "delete" = move to trash
	if [ -n "$unsafe" ]; then
		if [ -n "$verbose" ]; then echo -e "Deleting $red$1$norm"; fi
		#UNSAFE: permanently remove files.
		rm -rf -- "$1"
	else
		if [ -n "$verbose" ]; then echo -e "Moving $blue$1$norm to $red${trash}$norm"; fi
		# Check if target file exists
		filename=$(basename -- "$1")
		if [ -e "${trash}/${filename}" ]; then
			# If exists, rename target file to filename_timestamp
			timestamp=$(date +%Y%m%d_%H%M%S)
			# Also update original file's trashinfo
			if [ -f "${trash_dir}/logs/${filename}.trashinfo" ]; then
				mv "${trash_dir}/logs/${filename}.trashinfo" "${trash_dir}/logs/${filename}_${timestamp}.trashinfo"
			fi
			mv "${trash}/${filename}" "${trash}/${filename}_${timestamp}"
		fi
		mv -- "$1" "${trash}" # Move new file to trash
	fi
}

askfs() {
	[ ! -e "$1" ] && [ ! -L "$1" ] && return
	if [ "$(trash_dev "$1")" != "$(trash_dev "${trash}")" ]; then
		unset answer
		while true; do
			echo -e "Warning: $blue$1$norm is on a different device than trash. Proceed with unsafe deletion (y/n)?"
			read -r -n 1 answer
			echo
			case $answer in
			[Yy]*)
				unsafe="yes"
				break
				;;
			[Nn]*)
				return
				;;
			*)
				echo "Please enter 'y' for yes or 'n' for no."
				;;
			esac
		done
	fi
}

complain() {
	msg=""
	if [ ! -e "$1" -a ! -L "$1" ]; then # does not exist
		msg="File does not exist:"
	elif [ ! -w "$1" -a ! -L "$1" ]; then # not writable
		msg="File is not writable:"
	elif [ ! -f "$1" -a ! -d "$1" -a -z "$force" ]; then # Special or sth else.
		msg="Is not a regular file or directory (and -f not specified):"
	elif [ -f "$1" ]; then # is a file
		act="true" # operate on files by default
	elif [ -d "$1" -a -n "$recursive" ]; then # is a directory and recursive is enabled
		act="true"
	elif [ -d "$1" -a -z "${recursive}" ]; then
		msg="Is a directory (and -r not specified):"
	else
		# not file or dir. This branch should not be reached.
		msg="No such file or directory:"
	fi
}

asknobackup() {
	unset answer
	while true; do
		echo -e "Error: Unable to move $blue$1$norm to trash. Proceed with unsafe deletion (y/n)?"
		read -r -n 1 answer
		echo
		case $answer in
		[Yy]*)
			unsafe="yes"
			performdelete "$1"
			ret=$?
			break
			;;
		[Nn]*)
			break
			;;
		*)
			echo "Please enter 'y' for yes or 'n' for no."
			;;
		esac
	done
	# Reset temporary unsafe flag
	unset unsafe
}

deletefiles() {
	for k in "$@"; do
		fdesc="$blue$k$norm"
		complain "${k}"
		if [ -n "$msg" ]; then
			echo -e "$msg $fdesc."
		else
			orig_path=$(readlink -f -- "$k" 2>/dev/null || realpath -- "$k" 2>/dev/null || echo "${PWD}/${k#./}")
			if [ -z "$unsafe" ]; then
				askfs "${k}"
			fi
			do_unsafe=""
			[ -n "$unsafe" ] && do_unsafe=1
			performdelete "${k}"
			ret=$?
			if [[ "$answer" == [yY] ]]; then
				unset unsafe
				unset answer
			fi
			if [ ! "$ret" -eq 0 ]; then
				asknobackup "${k}"
			fi
			if [ -z "$no_log" ] && [ "$ret" -eq 0 ] && [ -z "$do_unsafe" ]; then
				trashinfo "${orig_path}" "${k}"
			fi
		fi
	done
}

# Add function to get folder size (in MB)
get_folder_size() {
	local folder="$1"
	local size=$(du -sm "$folder" | cut -f1)
	echo "$size"
}

# Modify cleanup function with space limit cleanup
cleanup_trash() {
	# Skip cleanup if disabled and not explicitly requested
	if { [ "$cleanup_days" -eq 0 ] && [ "$max_trash_size" -eq 0 ]; } || [ -z "$auto_cleanup" ]; then
		return 0
	fi
	if [ -n "$verbose" ]; then
		echo -e "Starting trash cleanup..."
	fi
	# Time-based cleanup
	if [ "$cleanup_days" -gt 0 ]; then
		current_time=$(date +%s)
		expire_time=$((current_time - cleanup_days * 86400))

		find "${trash}" -type f -print0 | while IFS= read -r -d '' file; do
			filename=$(basename "$file")
			trashinfo_file="${trash_dir}/logs/${filename}.trashinfo"

			file_time=$(stat -c %Y "$file")

			if [ $file_time -lt $expire_time ]; then
				if [ -n "$verbose" ]; then
					echo -e "Deleting expired file: ${blue}${filename}${norm}"
				fi
				rm -f "$file"
				[ -f "$trashinfo_file" ] && rm -f "$trashinfo_file"
			fi
		done
	fi

	# Size-based cleanup
	if [ "$max_trash_size" -gt 0 ]; then
		current_size=$(get_folder_size "${trash}")
		if [ "$current_size" -gt "$max_trash_size" ]; then
			if [ -n "$verbose" ]; then
				echo -e "Current trash size: ${blue}${current_size}MB${norm} exceeds limit of ${blue}${max_trash_size}MB${norm}"
				echo -e "Removing oldest files to free up space..."
			fi

			# Get all files sorted by time (oldest first)
			find "${trash}" -type f -printf '%T@ %p\n' | sort -n | while read -r timestamp filepath; do
				filename=$(basename "$filepath")
				trashinfo_file="${trash_dir}/logs/${filename}.trashinfo"

				if [ -n "$verbose" ]; then
					echo -e "Deleting old file: ${blue}${filename}${norm}"
				fi

				rm -f "$filepath"
				[ -f "$trashinfo_file" ] && rm -f "$trashinfo_file"

				# Recheck size
				current_size=$(get_folder_size "${trash}")
				if [ "$current_size" -le "$max_trash_size" ]; then
					if [ -n "$verbose" ]; then
						echo -e "Cleanup complete: Current size ${blue}${current_size}MB${norm} is within limit"
					fi
					break
				fi
			done
		fi
	fi
	if [ -n "$verbose" ]; then
		echo -e "Cleanup process completed"
	fi
}

# find out which flags were given
afteropts="" # boolean for end-of-options reached
for k in "$@"; do
	# if starts with dash and before end of options marker (--)
	if [ "${k:0:1}" == "-" -a -z "$afteropts" ]; then
		if [ "${k:1:2}" == "-" ]; then # if end of options marker
			afteropts="true"
		else # option(s)
			setflags "$k" # set flags
		fi
	else # not starting with dash, or after end-of-opts
		files[++i]="$k"
	fi
done

# Cleanup trash
cleanup_trash

# If cleanup only mode, exit after cleanup
if [ -n "$cleanup_only" ]; then
	exit 0
fi

if [ -z "${files[1]}" ]; then # no parameters?
	usagemessage # tell them how to use this
	exit 0
fi

# do the work
deletefiles "${files[@]}"
SAFEEOF
  chmod 755 /usr/local/bin/saferm
  mkdir -p /var/trash/files /var/trash/logs
  chmod 1777 /var/trash /var/trash/files /var/trash/logs
  _install_saferm_rm_alias
  _saferm_apply_to_current_shell
  ok "已写入 /usr/local/bin/saferm，已创建 /var/trash，并已配置 alias rm -> saferm（本会话已 source）"
}

uninstall_saferm() {
  hr; info "卸载 saferm"; echo ""
  _saferm_drop_current_shell_alias
  /bin/rm -f /usr/local/bin/saferm
  /bin/rm -f /etc/profile.d/saferm-rm.sh
  local f
  for f in /etc/zshrc /etc/bash.bashrc /etc/bashrc; do
    [[ -f "$f" ]] || continue
    sed -i '/# >>> saferm init.sh >>>/,/# <<< saferm init.sh <<</d' "$f"
  done
  ok "已移除 /usr/local/bin/saferm 与 rm 别名配置"
}

