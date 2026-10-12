#!/usr/bin/env python3
"""Publish exact signed bytes; the private signing key stays in login Keychain."""
import base64, hashlib, json, plistlib, subprocess
from pathlib import Path
root=Path(__file__).resolve().parent.parent
info=plistlib.loads((root/'App/Info.plist').read_bytes())
version=info['CFBundleShortVersionString']
archive=root/f'release/Kukusit-{version}-macOS-arm64.zip'
work=root/'.local/native-update'
work.mkdir(parents=True,exist_ok=True)
digest=hashlib.sha256()
with archive.open('rb') as source:
    for chunk in iter(lambda: source.read(1024*1024),b''):
        digest.update(chunk)
release_notes=(root/f'docs/release-v{version}.md').read_text()
app_notes='\n\n'.join('• '+line[2:] for line in release_notes.splitlines() if line.startswith('- '))
# The application presents the three user-facing changes; full technical notes stay on GitHub.
app_notes='\n\n'.join(app_notes.split('\n\n')[:3])
manifest=dict(schema=1,version=version,build=int(info['CFBundleVersion']),minimumOS=info['LSMinimumSystemVersion'],architecture='arm64',
    url=f'https://github.com/go1f/kukusit/releases/download/v{version}/{archive.name}',size=archive.stat().st_size,
    sha256=digest.hexdigest(),notes=app_notes)
payload=work/'manifest-payload.json'
payload.write_bytes(json.dumps(manifest,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode())
tool=root/'.local/sparkle/bin/sign_update'
if not tool.exists():
    raise SystemExit('Install the maintainer signing tool first; see docs/updating.md.')
signature=subprocess.check_output([str(tool),'-p','--disable-signing-warning',str(payload)],text=True).strip()
assert len(base64.b64decode(signature,validate=True)) == 64
output=root/'release/update.json'
output.write_text(json.dumps(dict(payload=base64.b64encode(payload.read_bytes()).decode(),signature=signature),separators=(',',':'))+'\n')
print(f'Signed manifest: {output}')
