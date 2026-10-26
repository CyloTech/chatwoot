"""Chatwoot checks for tests/smoke.sh, run inside the container with
`python3 -I - <command> [<arg>]` against http://127.0.0.1:3000.

EMAIL, PASSWORD and COMPANY come from the environment. Credentials and session
headers are never printed.

Commands:
  version                print the version /api reports; Redis and PostgreSQL
                         must both be ok
  login                  the admin signs in and is a SuperAdmin and an
                         administrator of the COMPANY account
  bad-login              the admin can no longer sign in with PASSWORD
  signups-closed         creating a new account is refused with 404
  create-contact <name>  add a contact to the COMPANY account
  has-contact <name>     the COMPANY account has that contact
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:3000"


def fail(message):
    print(f"FAIL {message}", file=sys.stderr)
    sys.exit(1)


def request(method, path, body=None, headers=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.headers, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.headers, err.read()


def sign_in(password):
    return request("POST", "/auth/sign_in", {"email": os.environ["EMAIL"], "password": password})


def session():
    status, headers, body = sign_in(os.environ["PASSWORD"])
    if status != 200:
        fail(f"sign in returned HTTP {status}")
    auth = {key: headers.get(key) for key in ("access-token", "client", "uid")}
    if not all(auth.values()):
        fail("sign in did not return session headers")
    user = json.loads(body)["data"]
    account = next((a for a in user.get("accounts", []) if a.get("name") == os.environ["COMPANY"]), None)
    if account is None:
        fail("the admin is not a member of the company account")
    return user, account, auth


def contact_path(account, suffix=""):
    return f"/api/v1/accounts/{int(account['id'])}/contacts{suffix}"


def contact_email(name):
    slug = "".join(c for c in name.lower() if c.isalnum())
    return f"{slug}@example.test"


command = sys.argv[1] if len(sys.argv) > 1 else ""

if command == "version":
    status, _, body = request("GET", "/api")
    if status != 200:
        fail(f"/api returned HTTP {status}")
    info = json.loads(body)
    if info.get("queue_services") != "ok" or info.get("data_services") != "ok":
        fail(f"/api reports queue_services={info.get('queue_services')} data_services={info.get('data_services')}")
    print(info["version"])

elif command == "login":
    user, account, _ = session()
    if user.get("type") != "SuperAdmin":
        fail(f"the admin has type {user.get('type')!r}, not SuperAdmin")
    if account.get("role") != "administrator":
        fail(f"the admin has role {account.get('role')!r} in the company account")
    print("ok   admin signs in as SuperAdmin and account administrator")

elif command == "bad-login":
    status, _, _ = sign_in(os.environ["PASSWORD"])
    if status != 401:
        fail(f"sign in with the old password returned HTTP {status}, expected 401")
    print("ok   the old password is refused")

elif command == "signups-closed":
    suffix = os.urandom(4).hex()
    status, _, _ = request("POST", "/api/v1/accounts", {
        "account_name": f"Signup {suffix}",
        "user_full_name": "Signup Test",
        "email": f"signup{suffix}@example.test",
        "password": f"Signup-{os.urandom(8).hex()}A1!",
    })
    if status != 404:
        fail(f"account signup returned HTTP {status}, expected 404")
    print("ok   account signup is closed")

elif command == "create-contact":
    name = sys.argv[2]
    _, account, auth = session()
    status, _, _ = request("POST", contact_path(account), {"name": name, "email": contact_email(name)}, auth)
    if status != 200:
        fail(f"creating a contact returned HTTP {status}")
    print(f"ok   created contact {name!r}")

elif command == "has-contact":
    name = sys.argv[2]
    _, account, auth = session()
    query = urllib.parse.urlencode({"q": contact_email(name)})
    status, _, body = request("GET", contact_path(account, f"/search?{query}"), None, auth)
    if status != 200:
        fail(f"contact search returned HTTP {status}")
    if not any(c.get("name") == name for c in json.loads(body).get("payload", [])):
        fail(f"contact {name!r} is missing")
    print(f"ok   contact {name!r} is present")

else:
    fail(f"unknown command {command!r}")
