#!/usr/bin/env python3
"""Register only this app's Chrome native messaging host; does not install the extension."""
import base64
import hashlib
import json
from pathlib import Path

project = Path(__file__).resolve().parent
manifest = json.loads((project / 'Extension/manifest.json').read_text())
hex_id = hashlib.sha256(base64.b64decode(manifest['key'])).hexdigest()[:32]
extension_id = ''.join(chr(ord('a') + int(c, 16)) for c in hex_id)
executable = Path.home() / 'Applications/Brightspace DDL.app/Contents/MacOS/DDLBridge'
if not executable.is_file():
    raise SystemExit('Install the newly built Mac app first.')
directory = Path.home() / 'Library/Application Support/Google/Chrome/NativeMessagingHosts'
directory.mkdir(parents=True, exist_ok=True)
path = directory / 'local.brightspace.ddl.json'
content = dict(name='local.brightspace.ddl', description='Local course deadline sync',
               path=str(executable), type='stdio', allowed_origins=[f'chrome-extension://{extension_id}/'])
path.write_text(json.dumps(content, indent=2) + '\n')
path.chmod(0o600)
print('Registered DDL bridge for extension ' + extension_id)
