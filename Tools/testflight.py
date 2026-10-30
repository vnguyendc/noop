#!/usr/bin/env python3
"""Archive NOOP (iPhone + Apple Watch), upload it to TestFlight, and release it to internal testers.

Needs an App Store Connect API key with Admin access, downloaded as a .p8 file. Set these in the
environment, or in the git-ignored Config/TestFlight.env (see Config/TestFlight.env.example):
  ASC_KEY_ID     the key's 10-character ID
  ASC_ISSUER_ID  the Issuer ID shown above the keys table
  ASC_KEY_PATH   optional; defaults to ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
The team and bundle ID prefix come from Config/Local.xcconfig, the same as a signed build.

Steps: xcodegen, archive with the next build number (the highest in App Store Connect plus one),
upload, wait for App Store Connect to finish processing, then add the build to any internal group that doesn't get every build
automatically. The key only goes to xcodebuild and to signing API tokens. It is never printed.

With TestFlight's Automatic Updates turned on for the app, the iPhone installs the new build by
itself, and the watch app comes with it.

Usage: Tools/testflight.py [--no-wait]
"""
import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API = "https://api.appstoreconnect.apple.com"
PROCESSING_TIMEOUT = 45 * 60


def read_settings(path):
    """KEY = VALUE lines from an .xcconfig (// comments) or an env file (# comments)."""
    settings = {}
    if not os.path.exists(path):
        return settings
    with open(path) as f:
        for line in f:
            if path.endswith(".xcconfig"):
                line = line.split("//", 1)[0]
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            settings[key.strip()] = value.strip().strip('"')
    return settings


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


# MARK: - App Store Connect API

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    """ES256 JWTs need the raw 64-byte r||s signature; openssl writes an ASN.1 DER sequence."""
    def read_len(i):
        n = der[i]
        if n < 0x80:
            return n, i + 1
        count = n & 0x7F
        return int.from_bytes(der[i + 1:i + 1 + count], "big"), i + 1 + count

    if der[0] != 0x30:
        raise ValueError("unexpected signature encoding")
    _, i = read_len(1)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("unexpected signature encoding")
        n, i = read_len(i + 1)
        parts.append(int.from_bytes(der[i:i + n], "big"))
        i += n
    return b"".join(p.to_bytes(32, "big") for p in parts)


class AppStoreConnect:
    def __init__(self, key_id, issuer_id, key_path):
        self.key_id, self.issuer_id, self.key_path = key_id, issuer_id, key_path
        self._token, self._token_exp = None, 0

    def token(self):
        now = int(time.time())
        if self._token and now < self._token_exp - 60:
            return self._token
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {"iss": self.issuer_id, "iat": now, "exp": now + 15 * 60, "aud": "appstoreconnect-v1"}
        signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}"
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.key_path],
                                input=signing_input.encode(), capture_output=True)
        if signed.returncode != 0:
            fail("couldn't sign an App Store Connect token with the key (check ASC_KEY_PATH)")
        self._token = f"{signing_input}.{b64url(der_to_raw(signed.stdout))}"
        self._token_exp = now + 15 * 60
        return self._token

    def request(self, method, path, query=None, body=None):
        url = API + path + ("?" + urllib.parse.urlencode(query) if query else "")
        req = urllib.request.Request(url, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {self.token()}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
                return json.loads(data) if data else {}
        except urllib.error.HTTPError as e:
            try:
                errors = json.loads(e.read()).get("errors", [])
                detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errors)
            except ValueError:
                detail = ""
            fail(f"App Store Connect {method} {path} returned {e.code}. {detail}".strip())


# MARK: - Build and upload

def run_logged(cmd, log_path, what):
    print(f"{what}… (log: {log_path})", flush=True)
    with open(log_path, "w") as log:
        result = subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        with open(log_path) as log:
            errors = [l.rstrip() for l in log if "error:" in l]
        print("\n".join(errors[-15:]), file=sys.stderr)
        fail(f"{what} failed (exit {result.returncode}); see {log_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--no-wait", action="store_true",
                        help="stop after the upload instead of waiting for processing")
    args = parser.parse_args()

    env = read_settings(os.path.join(ROOT, "Config", "TestFlight.env"))
    key_id = os.environ.get("ASC_KEY_ID") or env.get("ASC_KEY_ID")
    issuer_id = os.environ.get("ASC_ISSUER_ID") or env.get("ASC_ISSUER_ID")
    if not key_id or not issuer_id:
        fail("set ASC_KEY_ID and ASC_ISSUER_ID (environment or Config/TestFlight.env)")
    key_path = os.path.expanduser(os.environ.get("ASC_KEY_PATH") or env.get("ASC_KEY_PATH")
                                  or f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not os.path.isfile(key_path):
        fail(f"no API key file at {key_path}")

    signing = read_settings(os.path.join(ROOT, "Config", "Local.xcconfig"))
    team, prefix = signing.get("DEVELOPMENT_TEAM"), signing.get("BUNDLE_ID_PREFIX")
    if not team or not prefix:
        fail("set DEVELOPMENT_TEAM and BUNDLE_ID_PREFIX in Config/Local.xcconfig")
    bundle_id = f"{prefix}.noop"

    asc = AppStoreConnect(key_id, issuer_id, key_path)
    apps = asc.request("GET", "/v1/apps", {"filter[bundleId]": bundle_id, "fields[apps]": "name,bundleId"})["data"]
    if not apps:
        fail(f"no App Store Connect app for {bundle_id}; create it once (Apps > + > New App)")
    app_id, app_name = apps[0]["id"], apps[0]["attributes"]["name"]
    print(f"App Store Connect app: {app_name} ({bundle_id})")

    # Pick the build number here. Xcode's manageAppVersionAndBuildNumber uploaded the project's own
    # number (49) when 51 was already on TestFlight, and a lower number never installs as an update.
    builds = asc.request("GET", "/v1/builds", {"filter[app]": app_id, "limit": 200,
                                               "fields[builds]": "version"})["data"]
    numbers = [int(b["attributes"]["version"]) for b in builds if b["attributes"]["version"].isdigit()]
    build_number = max(numbers, default=0) + 1
    print(f"Build number: {build_number}")

    work = tempfile.mkdtemp(prefix="noop-testflight-")
    archive = os.path.join(work, "NOOP.xcarchive")
    auth = ["-allowProvisioningUpdates", "-authenticationKeyPath", key_path,
            "-authenticationKeyID", key_id, "-authenticationKeyIssuerID", issuer_id]

    run_logged(["xcodegen", "generate"], os.path.join(work, "xcodegen.log"), "Generating the project")
    run_logged(["xcodebuild", "archive", "-project", "Strand.xcodeproj", "-scheme", "NOOPiOS",
                "-configuration", "Release", "-destination", "generic/platform=iOS",
                "-archivePath", archive, f"CURRENT_PROJECT_VERSION={build_number}"] + auth,
               os.path.join(work, "archive.log"), "Archiving")

    options = os.path.join(work, "ExportOptions.plist")
    with open(options, "wb") as f:
        plistlib.dump({"method": "app-store-connect", "destination": "upload", "teamID": team,
                       "signingStyle": "automatic", "uploadSymbols": True,
                       "manageAppVersionAndBuildNumber": False,
                       "testFlightInternalTestingOnly": True}, f)
    uploaded_after = datetime.now(timezone.utc)
    run_logged(["xcodebuild", "-exportArchive", "-archivePath", archive, "-exportOptionsPlist", options,
                "-exportPath", os.path.join(work, "export")] + auth,
               os.path.join(work, "upload.log"), "Uploading to App Store Connect")
    print("Uploaded.")
    if args.no_wait:
        return

    # The new build shows up a few minutes after the upload, then processes.
    print("Waiting for App Store Connect to process the build (usually 5-30 min)…", flush=True)
    deadline, build = time.time() + PROCESSING_TIMEOUT, None
    while time.time() < deadline:
        builds = asc.request("GET", "/v1/builds", {
            "filter[app]": app_id, "sort": "-uploadedDate", "limit": 5,
            "fields[builds]": "version,processingState,uploadedDate,usesNonExemptEncryption"})["data"]
        # Allow for clock skew between this Mac and App Store Connect.
        fresh = [b for b in builds if b["attributes"]["version"] == str(build_number)
                 and datetime.fromisoformat(b["attributes"]["uploadedDate"]) >= uploaded_after - timedelta(minutes=2)]
        if fresh:
            build = fresh[0]
            state = build["attributes"]["processingState"]
            if state != "PROCESSING":
                break
        time.sleep(30)
    if not build:
        fail("the upload never appeared in App Store Connect; check the App Store Connect website")
    attrs = build["attributes"]
    if attrs["processingState"] != "VALID":
        fail(f"build {attrs['version']} is {attrs['processingState']}; check the email from App Store Connect")
    print(f"Build {attrs['version']} processed.")

    groups = asc.request("GET", f"/v1/apps/{app_id}/betaGroups",
                         {"fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds"})["data"]
    internal = [g for g in groups if g["attributes"].get("isInternalGroup")]
    if not internal:
        print("No internal testing group yet: create one in App Store Connect > TestFlight and add yourself.")
    for group in internal:
        name = group["attributes"]["name"]
        if group["attributes"].get("hasAccessToAllBuilds"):
            print(f"Internal group '{name}' gets every build automatically.")
            continue
        asc.request("POST", f"/v1/betaGroups/{group['id']}/relationships/builds",
                    body={"data": [{"type": "builds", "id": build["id"]}]})
        print(f"Added build {attrs['version']} to internal group '{name}'.")

    if attrs.get("usesNonExemptEncryption") is None:
        print("App Store Connect still wants the encryption answer for this build; answer it on the website.")
    print(f"Done. Build {attrs['version']} is in TestFlight; with Automatic Updates on, the iPhone installs it.")


if __name__ == "__main__":
    main()
