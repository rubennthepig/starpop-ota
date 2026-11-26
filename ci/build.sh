#!/usr/bin/env bash
set -Eeuo pipefail
channel=$PWD
# Ubuntu's util-linux runtime does not provide the unversioned libblkid
# linker library required by Reborn's native library tests.
if ! pkg-config --exists blkid; then
  sudo apt-get install -y libblkid-dev
fi
pkg-config --exists blkid
tag=${1:?release tag required}
[[ $tag =~ ^baseline-[0-9]+$ ]]
[[ ${tag#baseline-} -gt 275 ]]
mkdir -p "$RUNNER_TEMP/starpop-source"
cd "$RUNNER_TEMP/starpop-source"
for name in Y2Linux Y2Reborn; do
  git clone --filter=blob:none --no-checkout "https://github.com/SchulzCode/$name.git" "$name"
  git -C "$name" checkout --detach "$tag"
  git -C "$name" merge-base --is-ancestor baseline-275 HEAD
  git -C "$name" config user.name 'Starpop CI'
  git -C "$name" config user.email 'starpop@localhost'
done
# Never guess a changed partition contract or signing format.
git -C Y2Linux diff --quiet baseline-275 HEAD -- tools/production/layout.py tests/fixtures/production/MT6582_Android_scatter.txt tools/update/package.py || { echo 'Partition or OTA package format changed; manual review required'; exit 1; }
for pair in Y2Linux:linux Y2Reborn:reborn; do
  name=${pair%:*}; patch=${pair#*:}
  git -C "$name" apply --3way --index "$channel/patches/$patch.patch"
  if [[ $name == Y2Reborn ]]; then
    # The boot animation is raw RGB bytes, not whitespace-sensitive text.
    # Verify its exact Git blob against the archived patch before excluding
    # only that binary asset from the text whitespace check.
    python3 - "$channel/patches/$patch.patch" "$name" <<'PYRGB'
import pathlib,re,subprocess,sys
p=pathlib.Path(sys.argv[1]).read_bytes()
asset='crates/reborn-ui/src/starpop_boot.rgb'
header=b'diff --git a/'+asset.encode()+b' b/'+asset.encode()+b'\n'
assert p.count(header)==1, 'expected exactly one archived RGB asset'
part=p.split(header,1)[1].split(b'\ndiff --git ',1)[0]
match=re.search(rb'^index [0-9a-f]+\.\.([0-9a-f]{7,64})(?: |\n|$)',part,re.M)
assert match, 'missing archived RGB blob identity'
actual=subprocess.check_output(['git','-C',sys.argv[2],'rev-parse',':'+asset]).strip()
assert actual.startswith(match.group(1)), 'RGB bytes differ from archived asset'
print('Starpop boot RGB blob verified:',actual.decode())
PYRGB
    git -C "$name" diff --cached --check -- . ':(exclude)crates/reborn-ui/src/starpop_boot.rgb'
  else
    git -C "$name" diff --cached --check
  fi
  git -C "$name" commit -m 'Apply tested Starpop customizations'
done
python3 - "$channel/public-key.json" <<'PY'
import json, pathlib, sys
pub=json.loads(pathlib.Path(sys.argv[1]).read_text())['public_key_hex']
assert len(bytes.fromhex(pub))==32
p=pathlib.Path('Y2Linux/tools/update/trust.json'); t=json.loads(p.read_text())
assert t['schema']==1 and not any(k['id']=='starpop-ota-v1' for k in t['keys'])
t['keys'].append(dict(id='starpop-ota-v1',purpose='release',status='active',public_key_hex=pub,minimum_sequence=1,maximum_sequence=2147483647,allow_downgrade=False)); p.write_text(json.dumps(t,indent=2)+'\n')
p=pathlib.Path('Y2Linux/tools/update/channel.json'); t=json.loads(p.read_text()); t.update(name='Starpop',manifest_url='https://github.com/rubennthepig/starpop-ota/releases/latest/download/manifest.json'); p.write_text(json.dumps(t,indent=2)+'\n')
PY
git -C Y2Linux add tools/update/trust.json tools/update/channel.json
git -C Y2Linux commit -m 'Preserve Starpop OTA trust and channel'
# Install the exact toolchain specified by the release, rather than an unpinned nightly.
toolchain=$(python3 -c 'import tomllib; print(tomllib.load(open("Y2Reborn/rust-toolchain.toml","rb"))["toolchain"]["channel"])')
rustup toolchain install "$toolchain" --profile minimal --target armv7-unknown-linux-gnueabihf -c rustfmt -c clippy
(cd Y2Reborn; cargo fmt --all; if ! git diff --quiet; then git diff --check; git commit -am 'Format merged Starpop sources'; fi; cargo test --workspace --locked --offline)
(cd Y2Linux; python3 tools/build/prepare.py; python3 tools/production/build.py --output out/starpop --public)
mkdir -p "$channel/candidate"
build=Y2Linux/out/starpop
root="$build/buildroot/images/rootfs.ext4"
e2fsck -fn "$root"
test "$(blkid -p -s LABEL -o value "$root")" = Y2ROOT
test "$(blkid -p -s UUID -o value "$root")" = 79324c69-6e75-4801-8000-000000000101
# Verify that the built root actually carries our key and channel.
python3 - "$root" "$build/versions.json" "$channel/public-key.json" <<'PY'
import json, pathlib, subprocess, sys
root,versions,pub=sys.argv[1:]
def read(name): return json.loads(subprocess.check_output(['debugfs','-R','cat /etc/y2linux/'+name,root],stderr=subprocess.DEVNULL))
v=json.loads(pathlib.Path(versions).read_text()); assert v==read('versions.json')
assert v['layout_version']==v['data_schema_version']==1
assert v['platform_api_version']==1 and v['update_sequence']>18000
assert read('update-channel.json')['manifest_url']=='https://github.com/rubennthepig/starpop-ota/releases/latest/download/manifest.json'
assert any(k['id']=='starpop-ota-v1' and k['public_key_hex']==json.loads(pathlib.Path(pub).read_text())['public_key_hex'] for k in read('update-trust.json')['keys'])
PY
cp "$build/BOOTIMG.img" "$build/RECOVERY.img" "$build/versions.json" "$channel/candidate/"
cp --sparse=always "$root" "$channel/candidate/Y2ROOT.img"
# Preserve exact modified source trees, including commits and build inputs.
for name in Y2Linux Y2Reborn; do
  git -C "$name" archive --format=tar.gz --prefix="$name/" HEAD > "$channel/candidate/$name-source.tar.gz"
done
# Buildroot's legal-info target collects the third-party source/licence material.
# Use the release's own downloaded Buildroot version and build configuration.
br=$(python3 -c 'import json; print(json.load(open("Y2Linux/buildroot/inputs.lock.json"))["version"])')
BR2_DL_DIR="$PWD/Y2Linux/.cache/buildroot-dl" Y2_ARTIFACT_DIR="$PWD/$build" make -C "$PWD/Y2Linux/.cache/sources/buildroot-$br" O="$PWD/$build/buildroot" BR2_EXTERNAL="$PWD/Y2Linux/buildroot" legal-info
# Include the exact locked kernel and Buildroot archives as well.
mkdir -p "$channel/candidate/third-party"
cp Y2Linux/.cache/downloads/linux-*.tar.* Y2Linux/.cache/downloads/buildroot-*.tar.* "$channel/candidate/third-party/"
tar -C "$build/buildroot" -cf "$channel/candidate/third-party/buildroot-legal-info.tar" legal-info
# GitHub release assets must each be below 2 GiB.
for file in "$channel/candidate/third-party/"*; do
  if [[ $(stat -c %s "$file") -ge 1900000000 ]]; then
    split -b 1500M -d -a 3 "$file" "$file.part-"; rm "$file"
  fi
done
(cd "$channel/candidate"; sha256sum BOOTIMG.img RECOVERY.img Y2ROOT.img versions.json > SHA256SUMS)
