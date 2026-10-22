#!/usr/bin/env python3
"""Writes a fake Backup Suite release like the Release workflow's, served from
file:// URLs, whose installers only append a line to $UPDATE_MARK.

    make-fake-release.py <dir> <version> [evil]
"""
import hashlib, io, json, os, sys, tarfile
root, version = sys.argv[1:3]
evil = sys.argv[3] if len(sys.argv) > 3 else ""
top = "backup-suite-%s" % version
tag = "v" + version
os.makedirs(os.path.join(root, tag), exist_ok=True)
files = {
    top + "/VERSION": version + "\n",
    # Like the real installer: needs HOME (a systemd unit has none) under set -u.
    top + "/install.sh": '#!/bin/bash\nset -u\nprintf "install.sh %s home=%s\\n" "$*" "$HOME" >> "$UPDATE_MARK"\n',
    top + "/gui/scripts/backup-suite-gui-server": '#!/bin/bash\nprintf "gui-server %s\\n" "$*" >> "$UPDATE_MARK"\n',
}
if evil:
    files["../evil.txt"] = "outside\n"
archive = os.path.join(root, tag, top + ".tar.gz")
with tarfile.open(archive, "w:gz") as tar:
    for name, text in files.items():
        data = text.encode()
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o755
        tar.addfile(info, io.BytesIO(data))
digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
with open(archive + ".sha256", "w") as handle:
    handle.write("%s  %s\n" % (digest, os.path.basename(archive)))
base = "file://%s/" % root
release = {"tag_name": tag, "draft": False, "prerelease": False, "published_at": "2026-10-22T00:00:00Z",
           "html_url": "https://example.invalid/" + tag, "body": "notes",
           "assets": [{"name": os.path.basename(path), "size": os.path.getsize(path),
                       "browser_download_url": base + tag + "/" + os.path.basename(path)}
                      for path in (archive, archive + ".sha256")]}
with open(os.path.join(root, "latest.json"), "w") as handle:
    json.dump(release, handle)
