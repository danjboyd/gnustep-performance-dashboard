# Update-signing key procedure for Dan

These are manual provisioning steps for Dan. No product key or repository
setting has been created by the local preparation. Use a dedicated Ed25519
pair for Performance Dashboard updates. Keep the private PEM, DER and base64
seed files on encrypted offline storage, with an offline backup. Never put
them in the checkout, a release asset, a log, shell history, chat or mail.
The only online private copy required by this workflow is the GitHub Actions
repository secret. The public key is intended to be committed and packaged.

## Generate and export

On a trusted machine, use OpenSSL 3 in a **new empty directory on the private
storage**, outside every checkout. Disable shell tracing. These commands
write files rather than displaying key material:

```sh
set -eu
set +x
umask 077
openssl genpkey -algorithm ED25519 -out update-private.pem
openssl pkey -in update-private.pem -outform DER -out update-private.der
openssl pkey -in update-private.pem -pubout -outform DER -out update-public.der
python3 - <<'PY'
import base64
from pathlib import Path
private = Path('update-private.der').read_bytes()
public = Path('update-public.der').read_bytes()
private_prefix = bytes.fromhex('302e020100300506032b657004220420')
public_prefix = bytes.fromhex('302a300506032b6570032100')
if len(private) != len(private_prefix) + 32 or not private.startswith(private_prefix):
    raise SystemExit('unexpected private DER encoding; stop')
if len(public) != len(public_prefix) + 32 or not public.startswith(public_prefix):
    raise SystemExit('unexpected public DER encoding; stop')
for name, raw in [('update-private-seed.b64', private[len(private_prefix):]),
                  ('update-public.b64', public[len(public_prefix):])]:
    with open(name, 'x') as stream:
        stream.write(base64.b64encode(raw).decode('ascii') + '\n')
PY
```

The secret format is base64 of the raw **32-byte seed**, not PEM text, the
whole DER file, a passphrase or an OpenSSH key. The signer also accepts the
64-byte seed+matching-public form, but the procedure above uses 32 bytes.
Do not print the private file to inspect it. Retain all private derivatives
under the same offline protection; public files can leave that storage.

## Set the public trust anchor and Actions input

In `packaging/package.manifest.json`, replace `updates.publicEDKey: null`
with the single-line value from `update-public.b64` as a JSON string. This
public change needs its own reviewed commit before candidate packaging.
The release workflow also reads the **repository Actions variable**
`UPDATE_ED_PUBLIC_KEY`; give it that identical public value. For example,
from a trusted online machine with the public file available:

```sh
gh variable set UPDATE_ED_PUBLIC_KEY --repo danjboyd/gnustep-performance-dashboard < update-public.b64
```

Local release packaging takes the same public value in the environment.
It refuses a different value when the source manifest already names a key.
Inspect the packaged `gnustep-packager-update.json` and provenance for that
exact public key; payload signatures must verify before final feed assembly.

## Add the private repository secret

Dan adds `UPDATE_ED_PRIVATE_KEY` under repository **Settings → Secrets and
variables → Actions → Secrets → New repository secret**. Its value is the
single line in `update-private-seed.b64`. As an alternative, on Dan's trusted
online machine with a protected temporary copy available, pass the file on
stdin so the value is absent from command arguments and shell history:

```sh
gh secret set UPDATE_ED_PRIVATE_KEY --repo danjboyd/gnustep-performance-dashboard < update-private-seed.b64
```

The workflow receives it only in the payload-signing step. Keep offline
recovery copies; remove temporary online private copies after provisioning.
Do not rotate the public key casually: already installed clients trust the
key embedded when they were packaged. A change needs a migration plan.

The released v0.1.4 client contains no public key. Its initial update follows
the legacy HTTPS/SHA-256 path; the new signature cannot enforce trust on that
old client. Dan must choose and communicate the first trust-anchor delivery
before release. Provisioning keys alone does not finish update acceptance
or authorize a push, tag, publication or feed deployment.

Command references: [OpenSSL key generation](https://docs.openssl.org/3.0/man1/openssl-genpkey/),
[GitHub secret input](https://cli.github.com/manual/gh_secret_set) and
[GitHub variable input](https://cli.github.com/manual/gh_variable_set).
