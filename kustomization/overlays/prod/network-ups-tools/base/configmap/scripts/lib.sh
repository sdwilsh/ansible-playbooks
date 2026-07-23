#!/bin/sh

set -e

# require_env_error <name> <message>
# Callers run this via $(...) to capture stdout as a value; an echo on
# stdout here would be silently swallowed by the caller's command
# substitution instead of reaching the log, so this writes to stderr.
require_env_error() {
    if [ -z "$2" ]; then
        echo "$1 must be set!" >&2
    else
        echo "$1 must be set!  $2" >&2
    fi
    exit 1
}

# require_env <name> <value> <message>
# Exits with an error naming <name> and <message> if <value> is empty;
# otherwise prints <value>.
require_env() {
    name="$1"
    value="$2"
    message="$3"
    [ -n "${value}" ] || require_env_error "${name}" "${message}"
    printf '%s' "${value}"
}

# require_env_file <name> <path> <message>
# Same as require_env, but treats <path> as a file and prints its contents
# instead of the path itself.  The value is destined for a single-line NUT
# config directive, which has no escape sequence for an embedded newline
# (unlike a backslash or double quote, see nut_escape); an embedded newline
# would silently split the generated line and corrupt the config, so this
# fails loudly instead if one is present.  A single trailing newline (the
# normal case for a text-file secret) is fine; command substitution already
# strips it below.
require_env_file() {
    name="$1"
    path="$2"
    message="$3"
    [ -n "${path}" ] || require_env_error "${name}" "${message}"
    value=$(cat "${path}")
    line_count=$(printf '%s\n' "${value}" | wc -l)
    if [ "${line_count}" -ne 1 ]; then
        echo "${name} (${path}) contains an embedded newline, which cannot be represented in a NUT config value; regenerate this secret without one." >&2
        exit 1
    fi
    printf '%s' "${value}"
}

# nut_escape <value>
# Escapes backslashes and double quotes so <value> is safe to interpolate
# into a double-quoted NUT config value.
nut_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# write_config <dest> <content>
write_config() {
    dest="$1"
    content="$2"
    echo "Creating ${dest}..."
    printf '%s\n' "${content}" > "${dest}"
    echo "Successfully setup configuration at ${dest}"
}
