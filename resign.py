#!/usr/bin/env python3
"""Put each target's entitlements back into an exported .ipa and re-sign it.

The archive is built unsigned (the team has no registered devices, so automatic signing fails),
and exporting an unsigned archive signs every bundle with NO entitlements. App Store Connect then
rejects anything that needs them, e.g. an App Clip without on-demand-install-capable (90824).

For every bundle (deepest first) this takes the target's CODE_SIGN_ENTITLEMENTS file, resolves
$(AppIdentifierPrefix)/$(TeamIdentifierPrefix), keeps only keys its App Store profile grants (logging
any it has to drop), adds the profile's identity keys, and for App Clips adds
on-demand-install-capable. Then it re-signs and re-zips the .ipa in place.

usage: resign.py IPA CONTAINER_FLAG CONTAINER TEAM_ID IDENTITY KEYCHAIN
"""
import json, os, plistlib, shutil, subprocess, sys, tempfile

ipa, kind, container, team, identity, keychain = sys.argv[1:7]


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def log(msg):
    print(f"resign: {msg}", flush=True)


# Bundle ID -> entitlements file, from every target in the project (Release).
settings = json.loads(run("xcodebuild", "-showBuildSettings", "-json", kind, container, "-alltargets",
                          "-configuration", "Release").stdout)
src_root = os.path.dirname(container)
ent_files = {}
for t in settings:
    s = t["buildSettings"]
    bid, ent = s.get("PRODUCT_BUNDLE_IDENTIFIER"), s.get("CODE_SIGN_ENTITLEMENTS")
    if bid and ent:
        ent_files[bid] = ent if os.path.isabs(ent) else os.path.join(s.get("SRCROOT", src_root), ent)


def resolve(v):
    if isinstance(v, str):
        return v.replace("$(AppIdentifierPrefix)", team + ".").replace("$(TeamIdentifierPrefix)", team + ".")
    if isinstance(v, list):
        return [resolve(x) for x in v]
    if isinstance(v, dict):
        return {k: resolve(x) for k, x in v.items()}
    return v


def profile_entitlements(bundle):
    raw = run("security", "cms", "-D", "-i", os.path.join(bundle, "embedded.mobileprovision")).stdout
    return plistlib.loads(raw).get("Entitlements", {})


IDENTITY_KEYS = ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "beta-reports-active")

work = tempfile.mkdtemp(prefix="resign-")
try:
    run("ditto", "-x", "-k", ipa, work)
    bundles = []
    for root, dirs, _ in os.walk(os.path.join(work, "Payload")):
        for d in dirs:
            if d.endswith((".app", ".appex")):
                bundles.append(os.path.join(root, d))
    bundles.sort(key=lambda p: p.count(os.sep), reverse=True)

    changed = 0
    for b in bundles:
        info = plistlib.load(open(os.path.join(b, "Info.plist"), "rb"))
        bid = info["CFBundleIdentifier"]
        rel = os.path.relpath(b, work)
        is_clip = "/AppClips/" in "/" + rel + "/"
        want = resolve(plistlib.load(open(ent_files[bid], "rb"))) if bid in ent_files else {}
        if is_clip:
            want["com.apple.developer.on-demand-install-capable"] = True
        if not want:
            continue
        prof = profile_entitlements(b)
        ents = {k: prof[k] for k in IDENTITY_KEYS if k in prof}
        for k, v in want.items():
            if k in prof:
                ents[k] = v
            else:
                log(f"{bid}: profile doesn't grant {k}; leaving it out (enable the capability on the App ID)")
        # Nested code (frameworks, dylibs) keeps a plain signature.
        for root, dirs, files in os.walk(b):
            for n in dirs + files:
                if n.endswith((".framework", ".dylib")):
                    run("codesign", "-f", "-s", identity, "--keychain", keychain, os.path.join(root, n))
        ent_path = os.path.join(work, f"{bid}.entitlements.plist")
        plistlib.dump(ents, open(ent_path, "wb"))
        run("codesign", "-f", "-s", identity, "--keychain", keychain, "--entitlements", ent_path,
            "--generate-entitlement-der", b)
        log(f"{bid}: signed with {len(ents)} entitlements ({', '.join(sorted(k for k in ents if k not in IDENTITY_KEYS)) or 'identity only'})")
        changed += 1

    # Outer bundles were signed after their contents, so a final verify covers everything.
    for b in bundles:
        run("codesign", "--verify", "--deep", "--strict", b)
    if changed:
        tmp = ipa + ".tmp"
        if os.path.exists(tmp):
            os.remove(tmp)
        entries = sorted(e for e in os.listdir(work) if not e.endswith(".entitlements.plist"))
        subprocess.run(["zip", "-qry", "-X", tmp] + entries, cwd=work, check=True)
        os.replace(tmp, ipa)
    log(f"done: {changed} bundle(s) re-signed")
finally:
    shutil.rmtree(work, ignore_errors=True)
