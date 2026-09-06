"""Delete the olah cache when the image has a different version of olah.

olah cannot read a cache that a different version wrote.  The instruction from
the maintainers is to delete the cache directory by hand before an upgrade.
Renovate merges image updates without a person, so this script does that step.

The version comes from the package metadata in the image.  A value in the
Deployment keeps the old number after Renovate changes the tag, and the guard
then never acts.
"""

import contextlib
import os
import shutil
import sys
import tempfile
from importlib.metadata import PackageNotFoundError, version
from typing import List, Optional

ROOT = "/data/repos"
MARKER_NAME = ".olah-cache-version"
MARKER = os.path.join(ROOT, MARKER_NAME)


def read_marker() -> Optional[str]:
    """Return the version in the marker, or None when there is no marker.

    An empty marker gives None.  An empty marker is not a version, and a
    comparison against a version says the two differ.

    Any other error stops the script.  A read that fails for a different
    reason must not look like an absent marker, because the caller writes a
    new marker for an absent one.
    """
    try:
        with open(MARKER) as handle:
            return handle.read().strip() or None
    except FileNotFoundError:
        return None
    except OSError as error:
        raise SystemExit(f"Cannot read {MARKER}: {error}") from error


def write_marker(value: str) -> None:
    """Write the marker in one step.

    `open(MARKER, "w")` makes the file empty before it writes the bytes.  A
    crash between those two steps leaves an empty marker.  A rename puts the
    complete file in place in one operation.

    The mode of the temporary file becomes the mode of the marker, and the
    default mode gives no access to a different user.  The export maps all
    users to one user today, but the mode must not depend on that map.
    """
    handle, path = tempfile.mkstemp(dir=ROOT, prefix=f"{MARKER_NAME}.")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(f"{value}\n")
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
        os.replace(path, MARKER)
    except BaseException:
        # A failure to remove the temporary file must not hide the failure
        # that brought the script here.
        with contextlib.suppress(OSError):
            os.unlink(path)
        raise


def delete_cache() -> None:
    """Delete every item in the cache except the marker.

    An error does not stop the delete.  NFS makes a `.nfs` file when it
    deletes a file that another process holds open, and that file stops a
    directory delete.  The caller looks at what stays behind.
    """
    for name in os.listdir(ROOT):
        if name.startswith(MARKER_NAME):
            continue
        path = os.path.join(ROOT, name)
        with contextlib.suppress(OSError):
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                os.remove(path)


def leftovers() -> List[str]:
    return [name for name in os.listdir(ROOT) if not name.startswith(MARKER_NAME)]


def main() -> int:
    try:
        current = version("olah")
    except PackageNotFoundError:
        print("The image holds no olah package metadata.", file=sys.stderr)
        print("The guard cannot compare versions.  The cache stays.", file=sys.stderr)
        return 1

    previous = read_marker()

    if previous == current:
        print(f"The cache matches olah {current}.")
        return 0

    if previous is None:
        # A cache with files and no marker has an unknown version.  Do not
        # write a marker for it, because a marker that names the wrong
        # version hides a cache that olah cannot read.
        if leftovers():
            print("There is no marker, and the cache holds files.", file=sys.stderr)
            print("The guard cannot say which version wrote them.", file=sys.stderr)
            print(f"Delete the files, or write {MARKER} by hand.", file=sys.stderr)
            return 1
        print(f"The cache is empty.  The cache becomes olah {current}.")
    else:
        print(f"olah {previous} wrote the cache.  This image has olah {current}.")
        print("olah cannot read a cache from a different version.")
        print("Deleting the cache.  The next pull comes from Huggingface.")
        delete_cache()

        # Stop before the marker says the cache holds the new version.  A
        # marker that disagrees with the files sends the next start into a
        # second delete, and hides a cache that holds two formats.
        remaining = leftovers()
        if remaining:
            print(f"These items stay in the cache: {remaining}", file=sys.stderr)
            print("Delete them, then start the pod again.", file=sys.stderr)
            return 1

    write_marker(current)
    print(f"The marker says olah {current}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
