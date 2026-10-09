#!/usr/bin/env python3
"""gcs-hmac-test.py - test GCS HMAC credentials the way PBM < 2.10 uses them
(storage type s3, S3-compatible XML API, AWS Signature V4), with the Python
standard library only (works with the python3 of EL8, 3.6+).

Lists up to 1 object under the prefix and prints the HTTP status and the GCS
error code (AccessDenied, InvalidAccessKeyId, SignatureDoesNotMatch,
RequestTimeTooSkewed, ...), which tells why PBM gets "403 Forbidden".
Run it on a replica set member: it also tests the network path from there.

Usage (the access key id and secret are asked interactively, the secret
without echo; they are never passed as arguments):
  python3 gcs-hmac-test.py <bucket> <prefix> [region]
  python3 gcs-hmac-test.py -h | --help

Examples:
  python3 gcs-hmac-test.py mw-db-dumps mongodbcluster europe-west3
  sudo -u rmateos python3 /usr/local/share/doc/pbm-backup/gcs-hmac-test.py BackupBucket mongocluster/rs44

Exit codes: 0 the key can list the prefix, 1 HTTP/network error, 2 usage.
"""
import datetime
import getpass
import hashlib
import hmac
import sys
import urllib.error
import urllib.parse
import urllib.request

HOST = "storage.googleapis.com"


def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    bucket, prefix = sys.argv[1], sys.argv[2].strip("/")
    region = sys.argv[3] if len(sys.argv) > 3 else "auto"
    access = input("HMAC access key id: ").strip()
    secret = getpass.getpass("HMAC secret (hidden): ").strip()

    now = datetime.datetime.utcnow()
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    day = now.strftime("%Y%m%d")
    empty_hash = hashlib.sha256(b"").hexdigest()

    query = urllib.parse.urlencode(sorted({"max-keys": "1", "prefix": prefix + "/"}.items()),
                                   quote_via=urllib.parse.quote, safe="")
    canonical_uri = "/" + urllib.parse.quote(bucket)
    headers = "host:{}\nx-amz-content-sha256:{}\nx-amz-date:{}\n".format(HOST, empty_hash, amz_date)
    signed = "host;x-amz-content-sha256;x-amz-date"
    canonical = "\n".join(["GET", canonical_uri, query, headers, signed, empty_hash])
    scope = "{}/{}/s3/aws4_request".format(day, region)
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canonical.encode("utf-8")).hexdigest()])
    k = sign(("AWS4" + secret).encode("utf-8"), day)
    k = sign(k, region)
    k = sign(k, "s3")
    k = sign(k, "aws4_request")
    signature = hmac.new(k, to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    req = urllib.request.Request("https://{}{}?{}".format(HOST, canonical_uri, query), method="GET")
    req.add_header("x-amz-date", amz_date)
    req.add_header("x-amz-content-sha256", empty_hash)
    req.add_header("Authorization",
                   "AWS4-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}".format(
                       access, scope, signed, signature))
    print("GET https://{}{}?{}  (region {}, UTC {})".format(HOST, canonical_uri, query, region, amz_date))
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode("utf-8", "replace")
            print("HTTP {} OK: the key can list gs://{}/{}/".format(r.status, bucket, prefix))
            print(body[:600])
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        print("HTTP {}".format(e.code))
        print(body[:1200])
        sys.exit(1)
    except urllib.error.URLError as e:
        print("Network error: {}".format(e.reason))
        sys.exit(1)


if __name__ == "__main__":
    main()
