"""App-owned Sign in with ChatGPT. No Codex credentials or API-key fallback."""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from .config import APP_HOME

ISSUER = "https://auth.openai.com"
AUTHORIZE = ISSUER + "/api/accounts/authorize"
TOKEN = ISSUER + "/api/accounts/oauth/token"
RESOURCE = "https://api.openai.com/v1"
PLAN_SCOPE = "chatgpt.tokens.use.direct"
SCOPES = "openid profile email offline_access resource.invoke " + PLAN_SCOPE
AUTH_DIR = APP_HOME / "chatgpt"


class ChatGPTError(RuntimeError):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward a credential to a redirect destination.


def open_request(request, timeout=30):
    return urllib.request.build_opener(NoRedirect).open(request, timeout=timeout)


def safe_code(value) -> str:
    value = str(value or "request_failed")
    return value if re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", value) else "request_failed"


def api_error(error) -> ChatGPTError:
    code = "request_failed"
    try:
        body = json.loads(error.read(64_000))
        detail = body.get("error", {})
        code = safe_code(detail.get("code") or detail.get("type")) if isinstance(detail, dict) else safe_code(detail)
    except (ValueError, OSError, AttributeError):
        pass
    return ChatGPTError(f"ChatGPT request failed ({getattr(error, 'code', 'network')}: {code}).")


def request_json(url, *, form=None, token=None):
    headers = {"Accept": "application/json"}
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        with open_request(urllib.request.Request(url, data=data, headers=headers)) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise api_error(error) from None
    except (OSError, ValueError) as error:
        raise ChatGPTError("ChatGPT connection failed. Check your network and try again.") from None


@contextmanager
def storage_lock():
    AUTH_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    AUTH_DIR.chmod(0o700)
    fd = os.open(AUTH_DIR / "session.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def read_store():
    path = AUTH_DIR / "accounts.json"
    if path.exists():
        return json.loads(path.read_text())
    return {"host_id": "urn:uuid:" + str(uuid.uuid4()), "accounts": {}}


def write_store(store):
    fd, name = tempfile.mkstemp(dir=AUTH_DIR, prefix=".accounts-")
    try:
        with os.fdopen(fd, "w") as file:
            json.dump(store, file)
            file.flush()
            os.fsync(file.fileno())
        os.replace(name, AUTH_DIR / "accounts.json")
    finally:
        if os.path.exists(name):
            os.unlink(name)


def validate_identity(token, client_id, *, nonce=None, subject=None):
    try:
        import jwt
    except ImportError:
        raise ChatGPTError("Install the backend chatgpt optional dependencies first.") from None
    try:
        metadata = request_json(ISSUER + "/.well-known/openid-configuration")
        # Pin both issuer and the host allowed to supply signing keys.
        if metadata.get("issuer") != ISSUER or metadata.get("jwks_uri") != ISSUER + "/.well-known/jwks.json":
            raise ChatGPTError("Unexpected OpenAI identity configuration.")
        keys = request_json(metadata["jwks_uri"])
        header = jwt.get_unverified_header(token)
        if header.get("alg") != "RS256":
            raise ChatGPTError("Unsupported OpenAI identity signature.")
        key = next(k for k in keys["keys"] if k.get("kid") == header.get("kid"))
        claims = jwt.decode(token, jwt.PyJWK.from_dict(key).key, algorithms=["RS256"],
                            audience=client_id, issuer=ISSUER,
                            options={"require": ["exp", "iat", "sub", "iss", "aud"]})
        if not claims["sub"] or (subject is not None and claims["sub"] != subject):
            raise ChatGPTError("The signed-in ChatGPT account did not match the selected account.")
        if nonce is not None and not hmac.compare_digest(str(claims.get("nonce", "")), nonce):
            raise ChatGPTError("ChatGPT sign-in nonce did not match. Start sign-in again.")
        return claims
    except ChatGPTError:
        raise
    except Exception:
        raise ChatGPTError("Could not verify the OpenAI identity token. Start sign-in again.") from None


def updated_credentials(old, tokens):
    if tokens.get("token_type", "").lower() != "bearer" or not tokens.get("access_token"):
        raise ChatGPTError("OpenAI did not return bearer credentials.")
    expires = int(tokens.get("expires_in", 0))
    if expires <= 0:
        raise ChatGPTError("OpenAI returned an invalid credential expiry.")
    scopes = tokens["scope"].split() if "scope" in tokens else old.get("scopes", [])
    return {**old, **{k: tokens.get(k, old.get(k)) for k in ("access_token", "refresh_token", "id_token")},
            "scopes": scopes, "expires_at": time.time() + expires}


def access_token(client_id):
    with storage_lock():
        store = read_store()
        account = store["accounts"].get(client_id)
        if not account or not account.get("access_token"):
            raise ChatGPTError("Sign in to ChatGPT in Models settings first.")
        if PLAN_SCOPE not in account.get("scopes", []):
            raise ChatGPTError("ChatGPT plan usage was not authorized. Sign in and grant plan usage.")
        if account["expires_at"] <= time.time() + 60:
            if not account.get("refresh_token"):
                raise ChatGPTError("ChatGPT sign-in expired. Sign in again.")
            tokens = request_json(TOKEN, form={"grant_type": "refresh_token", "client_id": client_id,
                                   "refresh_token": account["refresh_token"], "resource": RESOURCE})
            if tokens.get("id_token"):
                validate_identity(tokens["id_token"], client_id, subject=account["subject"])
            account = updated_credentials(account, tokens)
            store["accounts"][client_id] = account
            write_store(store)
            if PLAN_SCOPE not in account["scopes"]:
                raise ChatGPTError("ChatGPT plan permission is no longer available.")
        return account["access_token"]


def status():
    with storage_lock():
        store = read_store()
        return {"accounts": [{"id": key, "label": value.get("email") or value["subject"],
                              "signed_in": bool(value.get("access_token")),
                              "plan_enabled": bool(value.get("access_token")) and PLAN_SCOPE in value.get("scopes", [])}
                             for key, value in store["accounts"].items()]}


def authorize_parameters(host, redirect, state, nonce, verifier, account=None):
    params = {"client_id": account["client_id"] if account else "dynamic_agent_client",
              "ext_agent_host_id": host, "redirect_uri": redirect, "response_type": "code",
              "scope": SCOPES, "resource": RESOURCE, "state": state, "nonce": nonce,
              "code_challenge_method": "S256",
              "code_challenge": base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()}
    if account:
        if account.get("id_token"):
            params["id_token_hint"] = account["id_token"]
    else:
        params["agent_name_hint"] = "Photo Search"
    return params


def callback_values(path, state, client_id=None):
    url = urllib.parse.urlsplit(path)
    values = urllib.parse.parse_qs(url.query)
    if url.path != "/auth/callback" or any(len(v) != 1 for v in values.values()):
        raise ChatGPTError("Invalid ChatGPT callback.")
    values = {k: v[0] for k, v in values.items()}
    if not hmac.compare_digest(values.get("state", ""), state):
        raise ChatGPTError("ChatGPT callback state did not match.")
    if values.get("error"):
        raise ChatGPTError("ChatGPT sign-in declined (" + safe_code(values["error"]) + ").")
    issued = values.get("client_id", client_id)
    if not issued or issued == "dynamic_agent_client" or not re.fullmatch(r"[A-Za-z0-9_-]{1,200}", issued):
        raise ChatGPTError("ChatGPT registration did not return an issued client ID.")
    if client_id and issued != client_id:
        raise ChatGPTError("ChatGPT registration changed unexpectedly.")
    if not values.get("code"):
        raise ChatGPTError("ChatGPT sign-in did not return an authorization code.")
    return issued, values["code"]


def login(emit, client_id=None):
    with storage_lock():
        fd = os.open(AUTH_DIR / "login.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ChatGPTError("A ChatGPT sign-in is already in progress. Finish or cancel it first.") from None
        return _login(emit, client_id)


def _login(emit, client_id=None):
    with storage_lock():
        store = read_store()
        write_store(store)  # Persist the stable host ID before registration.
        account = store["accounts"].get(client_id) if client_id else None
        if client_id and account is None:
            raise ChatGPTError("The selected ChatGPT registration was not found.")
    state, nonce, verifier = (secrets.token_urlsafe(32) for _ in range(3))
    received = {}

    class Callback(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Callback URLs contain authorization codes.

        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if parsed.path != "/auth/callback" or query.get("state") != [state]:
                self.send_error(400, "Invalid sign-in callback")
                return
            received["path"] = self.path
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(b"<title>Photo Search</title><p>Return to Photo Search to check sign-in.</p>")

    with HTTPServer(("127.0.0.1", 0), Callback) as server:
        server.timeout = 1
        redirect = f"http://127.0.0.1:{server.server_port}/auth/callback"
        params = authorize_parameters(store["host_id"], redirect, state, nonce, verifier, account)
        # This event goes only to the app's pipe, never to a persistent log.
        emit({"event": "authorize", "url": AUTHORIZE + "?" + urllib.parse.urlencode(params)})
        deadline = time.monotonic() + 600
        while not received and time.monotonic() < deadline:
            server.handle_request()
    if not received:
        raise ChatGPTError("ChatGPT sign-in timed out. Try again.")
    issued, code = callback_values(received["path"], state, client_id)
    tokens = request_json(TOKEN, form={"grant_type": "authorization_code", "client_id": issued,
                          "code": code, "code_verifier": verifier, "redirect_uri": redirect, "resource": RESOURCE})
    claims = validate_identity(tokens.get("id_token", ""), issued, nonce=nonce,
                               subject=account["subject"] if account else None)
    record = updated_credentials({"client_id": issued, "subject": claims["sub"],
                                  "email": claims.get("email", ""), "issuer": ISSUER}, tokens)
    with storage_lock():
        store = read_store()
        existing = store["accounts"].get(issued)
        if existing and existing["subject"] != record["subject"]:
            raise ChatGPTError("This ChatGPT client belongs to a different saved account.")
        store["accounts"][issued] = record
        write_store(store)
    return {"event": "signed_in", "account_id": issued, **status()}


def list_models(client_id):
    result = request_json(RESOURCE + "/models", token=access_token(client_id))
    return [{"id": item["slug"], "name": item.get("display_name", item["slug"])}
            for item in result.get("models", []) if item.get("visibility") == "list" and item.get("slug")]


def signout(client_id):
    with storage_lock():
        store = read_store()
        account = store["accounts"].get(client_id)
        if account is None:
            return {"revoked": True}
        revoked = False
        try:
            # Discovery may evolve; pin the credential destination to auth.openai.com.
            meta = request_json(ISSUER + "/.well-known/openid-configuration")
            endpoint = meta.get("revocation_endpoint", "")
            if endpoint != ISSUER + "/api/accounts/oauth/revoke":
                raise ChatGPTError("Unexpected session revocation endpoint.")
            if account.get("refresh_token"):
                data = urllib.parse.urlencode({"token": account["refresh_token"], "token_type_hint": "refresh_token", "client_id": client_id}).encode()
                request = urllib.request.Request(endpoint, data=data, headers={"Content-Type": "application/x-www-form-urlencoded"})
                with open_request(request) as response:
                    revoked = response.status == 200
            else:
                revoked = True
        except (ChatGPTError, OSError):
            pass
        # Keep the identity/client mapping, clear all local credentials.
        store["accounts"][client_id] = {k: v for k, v in account.items() if k in ("client_id", "subject", "email", "issuer")}
        write_store(store)
    return {"revoked": revoked, **status()}


def command(argv):
    parser = argparse.ArgumentParser(prog="photo-search chatgpt")
    parser.add_argument("action", choices=["status", "login", "models", "test", "signout"])
    parser.add_argument("--account")
    parser.add_argument("--model")
    args = parser.parse_args(argv)
    def emit(event):
        print(json.dumps(event), flush=True)
    try:
        if args.action == "status":
            emit(status())
        elif args.action == "login":
            emit(login(emit, args.account))
        elif args.action == "models":
            emit({"models": list_models(args.account)})
        elif args.action == "signout":
            emit(signout(args.account))
        else:
            from .chatgpt_client import test_image
            emit(test_image(args.account, args.model))
        return 0
    except (ChatGPTError, ValueError, OSError):
        import sys
        error = sys.exc_info()[1]
        emit({"error": str(error) if isinstance(error, ChatGPTError) else "ChatGPT operation failed. Try again."})
        return 1
