#!/usr/bin/env python3
"""Synchronize cert-manager's public chain with Stalwart's default certificate.

Only public certificates and API credentials are read. The private-key path is
sent to Stalwart as a server-side File reference, never opened by this process.
A cycle is successful only after a trusted, hostname-checked local TLS handshake
serves the projected leaf. --once performs one bounded cycle and exits 0 or 1.
"""

import argparse
import base64
import hashlib
import json
import math
import os
import re
import socket
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


MAX_PUBLIC_BYTES = 1024 * 1024
MAX_CREDENTIAL_BYTES = 16384
REQUEST_TIMEOUT = 5.0
RECONCILE_TIMEOUT = 30.0
RETRY_INTERVAL = 2.0
PEM_BLOCK = re.compile(
    r"-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*"
    r"-----END CERTIFICATE-----"
)
SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")
JMAP_ERROR_TYPES = frozenset(
    {
        "accountNotFound", "accountNotSupportedByMethod", "accountReadOnly",
        "forbidden", "invalidArguments", "invalidProperties", "notFound",
        "overQuota", "requestTooLarge", "serverFail", "serverPartialFail",
        "stateMismatch", "tooManyChanges", "unknownMethod", "unsupportedFilter",
        "unsupportedSort", "unknownCapability", "cannotCalculateChanges",
        "alreadyExists", "inUse", "invalidPatch", "willDestroy",
    }
)


class SyncError(Exception):
    """An error whose category is safe to log without its underlying exception."""

    def __init__(self, category: str):
        self.category = category
        super().__init__(category)


class ApiTransportError(SyncError):
    pass


class ApiProtocolError(SyncError):
    pass


class JmapMethodError(SyncError):
    def __init__(self, error: object):
        self.error_type = safe_jmap_error_type(error)
        super().__init__(f"jmap_method_{self.error_type}")


class JmapSetError(SyncError):
    def __init__(self, operation: str, error: object):
        self.error_type = safe_jmap_error_type(error)
        super().__init__(f"jmap_{operation}_{self.error_type}")


class PublicCertificateError(SyncError):
    pass


class ProjectionChanged(SyncError):
    def __init__(self):
        super().__init__("public_projection_changed")


class ServedCertificateError(SyncError):
    pass


def safe_jmap_error_type(error: object) -> str:
    error_type = error.get("type") if isinstance(error, dict) else None
    return error_type if isinstance(error_type, str) and error_type in JMAP_ERROR_TYPES else "unknown_error"


def remaining(deadline: float) -> float:
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise SyncError("reconciliation_deadline")
    return min(REQUEST_TIMEOUT, seconds)


def read_bounded(path: Path, limit: int, category: str) -> bytes:
    try:
        with path.open("rb") as source:
            data = source.read(limit + 1)
    except OSError:
        raise SyncError(category) from None
    if len(data) > limit:
        raise SyncError(category)
    return data


@dataclass(frozen=True)
class Config:
    api_url: str
    connect_host: str
    tls_host: str
    tls_port: int
    cert_path: Path
    key_path: str
    credential_dir: Path
    interval: float

    @classmethod
    def from_environment(cls) -> "Config":
        try:
            url = urllib.parse.urlsplit(
                os.environ.get("STALWART_URL", "http://127.0.0.1:8080").rstrip("/")
            )
            host = url.hostname
            if (
                url.scheme not in {"http", "https"}
                or host not in {"127.0.0.1", "::1", "localhost"}
                or url.username is not None
                or url.password is not None
                or url.query
                or url.fragment
                or url.path not in {"", "/"}
                or (url.port is not None and not 1 <= url.port <= 65535)
            ):
                raise ValueError
            tls_host = os.environ.get("STALWART_TLS_HOST", "mail.macbytes.io")
            if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", tls_host):
                raise ValueError
            tls_port = int(os.environ.get("STALWART_TLS_PORT", "9993"))
            interval = float(os.environ.get("STALWART_SYNC_INTERVAL", "60"))
            if not 1 <= tls_port <= 65535 or not math.isfinite(interval) or interval <= 0:
                raise ValueError
            key_path = os.environ.get("STALWART_KEY_PATH", "/etc/stalwart/tls/tls.key")
            if not Path(key_path).is_absolute():
                raise ValueError
            return cls(
                api_url=urllib.parse.urlunsplit((url.scheme, url.netloc, "/jmap/", "", "")),
                connect_host=host,
                tls_host=tls_host.lower(),
                tls_port=tls_port,
                cert_path=Path(os.environ.get(
                    "STALWART_CERT_PATH", "/etc/stalwart/public-tls/tls.crt"
                )),
                key_path=key_path,
                credential_dir=Path(os.environ.get(
                    "STALWART_CREDENTIAL_DIR", "/run/stalwart-tls-sync"
                )),
                interval=interval,
            )
        except (TypeError, ValueError):
            raise SyncError("invalid_configuration") from None


def read_credentials(directory: Path) -> tuple[str, str]:
    values = []
    for name in ("api-key", "account-id"):
        raw = read_bounded(directory / name, MAX_CREDENTIAL_BYTES, "credentials_unavailable")
        try:
            value = raw.decode("ascii").strip()
        except UnicodeDecodeError:
            raise SyncError("credentials_invalid") from None
        if not value or any(ord(character) < 33 or ord(character) > 126 for character in value):
            raise SyncError("credentials_invalid")
        values.append(value)
    return values[0], values[1]


def parse_chain(pem: str) -> tuple[bytes, ...]:
    blocks = list(PEM_BLOCK.finditer(pem))
    if not blocks:
        raise PublicCertificateError("public_certificate_malformed")
    end = 0
    certificates = []
    try:
        for block in blocks:
            if pem[end:block.start()].strip():
                raise ValueError
            encoded = "".join(block.group(1).split())
            der = base64.b64decode(encoded, validate=True)
            if not der:
                raise ValueError
            certificates.append(der)
            end = block.end()
        if pem[end:].strip():
            raise ValueError
    except ValueError:
        raise PublicCertificateError("public_certificate_malformed") from None
    return tuple(certificates)


def decode_leaf(der: bytes) -> dict:
    # CPython has no public X.509 metadata decoder. This helper is available in
    # the pinned CPython image; the temporary file contains one PUBLIC leaf only.
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="ascii", prefix="stalwart-public-", suffix=".pem"
        ) as public_file:
            public_file.write(ssl.DER_cert_to_PEM_cert(der))
            public_file.flush()
            return ssl._ssl._test_decode_cert(public_file.name)
    except (OSError, ssl.SSLError, ValueError):
        raise PublicCertificateError("public_certificate_malformed") from None


def dns_matches(name: str, hostname: str) -> bool:
    name = name.lower().rstrip(".")
    hostname = hostname.lower().rstrip(".")
    if "*" not in name:
        return name == hostname
    # Match only a complete leftmost DNS label, never multiple labels or a
    # partial wildcard. The TLS handshake independently enforces hostname rules.
    return (
        name.startswith("*.")
        and name.count("*") == 1
        and name.count(".") >= 2
        and hostname.count(".") == name.count(".")
        and hostname.split(".", 1)[1] == name[2:]
    )


def leaf_names(decoded: dict) -> frozenset[str]:
    return frozenset(
        value.lower().rstrip(".")
        for kind, value in decoded.get("subjectAltName", ())
        if kind in {"DNS", "IP Address"}
    )


def leaf_matches_host(decoded: dict, hostname: str) -> bool:
    # A SAN is required; do not fall back to a legacy commonName identity.
    return any(
        kind == "DNS" and dns_matches(value, hostname)
        for kind, value in decoded.get("subjectAltName", ())
    )


def parse_api_time(value: object) -> float | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return parsed.timestamp()
    except (ValueError, OverflowError):
        return None


@dataclass(frozen=True)
class PublicCertificate:
    raw: bytes
    pem: str
    chain: tuple[bytes, ...]
    names: frozenset[str]
    not_before: float
    not_after: float
    context: ssl.SSLContext

    @classmethod
    def load(cls, config: Config) -> "PublicCertificate":
        raw = read_bounded(config.cert_path, MAX_PUBLIC_BYTES, "public_certificate_unavailable")
        try:
            pem = raw.decode("ascii")
        except UnicodeDecodeError:
            raise PublicCertificateError("public_certificate_malformed") from None
        chain = parse_chain(pem)
        decoded = decode_leaf(chain[0])
        try:
            not_before = ssl.cert_time_to_seconds(decoded["notBefore"])
            not_after = ssl.cert_time_to_seconds(decoded["notAfter"])
            # Trust only this projected chain. Partial-chain trust allows the
            # projected leaf/intermediate to be an anchor without a root PEM.
            context = ssl.create_default_context(cadata=pem)
            context.verify_flags |= ssl.VERIFY_X509_PARTIAL_CHAIN
        except (KeyError, ValueError, ssl.SSLError):
            raise PublicCertificateError("public_certificate_malformed") from None
        if not leaf_matches_host(decoded, config.tls_host):
            raise PublicCertificateError("public_certificate_wrong_san")
        certificate = cls(raw, pem, chain, leaf_names(decoded), not_before, not_after, context)
        certificate.check_validity()
        return certificate

    def check_validity(self) -> None:
        now = time.time()
        if now < self.not_before:
            raise PublicCertificateError("public_certificate_not_yet_valid")
        if now >= self.not_after:
            raise PublicCertificateError("public_certificate_expired")

    def assert_projection(self, config: Config) -> None:
        if read_bounded(config.cert_path, MAX_PUBLIC_BYTES, "public_certificate_unavailable") != self.raw:
            raise ProjectionChanged()
        self.check_validity()

    def metadata_matches(self, record: dict) -> bool:
        names = record.get("subjectAlternativeNames")
        if not isinstance(names, dict) or any(
            not isinstance(name, str) or enabled is not True for name, enabled in names.items()
        ):
            return False
        return (
            frozenset(name.lower().rstrip(".") for name in names) == self.names
            and parse_api_time(record.get("notValidBefore")) == self.not_before
            and parse_api_time(record.get("notValidAfter")) == self.not_after
        )

    def text_matches(self, value: object) -> bool:
        if not isinstance(value, dict) or value.get("@type") != "Text":
            return False
        text = value.get("value")
        if not isinstance(text, str):
            return False
        try:
            return parse_chain(text) == self.chain
        except PublicCertificateError:
            return False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        # Never forward the bearer credential to an advertised or redirected URL.
        return None


class JmapClient:
    def __init__(self, config: Config, deadline: float):
        self.config = config
        self.deadline = deadline
        self.api_key, self.account_id = read_credentials(config.credential_dir)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, method: str, arguments: dict) -> dict:
        request_body = {
            "using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"],
            "methodCalls": [[method, {"accountId": self.account_id, **arguments}, "tls"]],
        }
        request = urllib.request.Request(
            self.config.api_url,
            data=json.dumps(request_body).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method="POST",
        )
        try:
            with self.opener.open(request, timeout=remaining(self.deadline)) as response:
                body = response.read(MAX_PUBLIC_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise ApiTransportError(f"api_http_{error.code}") from None
        except (urllib.error.URLError, OSError, ValueError):
            raise ApiTransportError("api_transport_failed") from None
        if len(body) > MAX_PUBLIC_BYTES:
            raise ApiProtocolError("api_response_too_large")
        try:
            payload = json.loads(body)
        except (UnicodeDecodeError, ValueError):
            raise ApiProtocolError("api_response_invalid_json") from None
        responses = payload.get("methodResponses") if isinstance(payload, dict) else None
        if not isinstance(responses, list) or len(responses) != 1:
            raise ApiProtocolError("jmap_response_invalid")
        response = responses[0]
        if not isinstance(response, list) or len(response) != 3 or response[2] != "tls":
            raise ApiProtocolError("jmap_response_invalid")
        if response[0] == "error":
            raise JmapMethodError(response[1])
        if response[0] != method or not isinstance(response[1], dict):
            raise ApiProtocolError("jmap_response_invalid")
        result = response[1]
        if result.get("accountId", self.account_id) != self.account_id:
            raise ApiProtocolError("jmap_account_mismatch")
        return result

    def get_one(self, method: str, identifier: str, properties: list[str]) -> dict | None:
        result = self.call(method, {"ids": [identifier], "properties": properties})
        records, missing = result.get("list"), result.get("notFound")
        if not isinstance(records, list) or not isinstance(missing, list):
            raise ApiProtocolError("jmap_get_invalid")
        if records == [] and missing == [identifier]:
            return None  # Only an explicit notFound permits certificate recreation.
        if (
            len(records) != 1 or missing != [] or not isinstance(records[0], dict)
            or records[0].get("id") != identifier
        ):
            raise ApiProtocolError("jmap_get_invalid")
        return records[0]

    def default_id(self) -> str | None:
        settings = self.get_one(
            "x:SystemSettings/get", "singleton", ["id", "defaultCertificateId"]
        )
        if settings is None:
            raise ApiProtocolError("system_settings_absent")
        identifier = settings.get("defaultCertificateId")
        if identifier is None or identifier == "":
            return None
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier):
            raise ApiProtocolError("default_certificate_id_invalid")
        return identifier

    def certificate(self, identifier: str) -> dict | None:
        return self.get_one(
            "x:Certificate/get", identifier,
            ["id", "certificate", "notValidBefore", "notValidAfter", "subjectAlternativeNames"],
        )

    def update(self, method: str, identifier: str, properties: dict) -> None:
        result = self.call(method, {"update": {identifier: properties}})
        rejected = result.get("notUpdated", {})
        if not isinstance(rejected, dict):
            raise ApiProtocolError("jmap_update_invalid")
        if identifier in rejected:
            raise JmapSetError("update", rejected[identifier])
        updated = result.get("updated")
        if not isinstance(updated, dict) or identifier not in updated or rejected:
            raise ApiProtocolError("jmap_update_invalid")

    def create(self, method: str, creation_id: str, properties: dict) -> dict:
        result = self.call(method, {"create": {creation_id: properties}})
        rejected = result.get("notCreated", {})
        if not isinstance(rejected, dict):
            raise ApiProtocolError("jmap_create_invalid")
        if creation_id in rejected:
            raise JmapSetError("create", rejected[creation_id])
        created = result.get("created")
        if (
            not isinstance(created, dict) or creation_id not in created or rejected
            or not isinstance(created[creation_id], dict)
        ):
            raise ApiProtocolError("jmap_create_invalid")
        return created[creation_id]

    def matching_certificate(self, public: PublicCertificate) -> str | None:
        # Recover a successful create whose reply/default update was lost.
        # Never create another object until the server confirms no match exists.
        result = self.call("x:Certificate/query", {"limit": 100, "calculateTotal": True})
        identifiers = result.get("ids")
        if (
            not isinstance(identifiers, list)
            or result.get("total") != len(identifiers)
            or any(not isinstance(item, str) or not SAFE_ID.fullmatch(item) for item in identifiers)
        ):
            raise ApiProtocolError("certificate_recovery_query_incomplete")
        matches = []
        for identifier in identifiers:
            record = self.certificate(identifier)
            if record is not None and public.text_matches(record.get("certificate")):
                if public.metadata_matches(record):
                    matches.append(identifier)
        if len(matches) > 1:
            raise SyncError("certificate_recovery_ambiguous")
        return matches[0] if matches else None

    def reload(self) -> None:
        self.create("x:Action/set", "reload", {"@type": "ReloadTlsCertificates"})


def assert_managed(record: dict, public: PublicCertificate, config: Config) -> None:
    value = record.get("certificate")
    if not isinstance(value, dict):
        raise SyncError("default_certificate_unmanaged")
    if value.get("@type") == "File" and value.get("filePath") == str(
        Path(config.key_path).with_name("tls.crt")
    ):
        return
    if value.get("@type") == "Text" and isinstance(value.get("value"), str):
        try:
            existing_chain = parse_chain(value["value"])
            if existing_chain[0] == public.chain[0] or leaf_matches_host(
                decode_leaf(existing_chain[0]), config.tls_host
            ):
                return
        except PublicCertificateError:
            pass
    raise SyncError("default_certificate_unmanaged")


def assert_default(client: JmapClient, expected: str | None) -> None:
    if client.default_id() != expected:
        raise SyncError("default_certificate_changed")


def verify_served(config: Config, public: PublicCertificate, deadline: float) -> None:
    public.check_validity()
    try:
        with socket.create_connection(
            (config.connect_host, config.tls_port), timeout=remaining(deadline)
        ) as connection:
            connection.settimeout(remaining(deadline))
            with public.context.wrap_socket(connection, server_hostname=config.tls_host) as tls:
                peer_der = tls.getpeercert(binary_form=True)
                peer = tls.getpeercert()
    except ssl.SSLCertVerificationError:
        raise ServedCertificateError("served_tls_verification_failed") from None
    except (OSError, ssl.SSLError, ValueError):
        raise ServedCertificateError("served_tls_unavailable") from None
    if peer_der != public.chain[0]:
        raise ServedCertificateError("served_tls_leaf_mismatch")
    try:
        expires = ssl.cert_time_to_seconds(peer["notAfter"])
    except (KeyError, ValueError):
        raise ServedCertificateError("served_tls_metadata_invalid") from None
    if expires != public.not_after or time.time() >= expires:
        raise ServedCertificateError("served_tls_expired")


def retry_pause(deadline: float, error: SyncError) -> None:
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise error
    time.sleep(min(RETRY_INTERVAL, seconds))
    if time.monotonic() >= deadline:
        raise error


def reload_and_verify(client: JmapClient, public: PublicCertificate, deadline: float) -> None:
    # Public and private-key projections belong to different volumes. The API
    # write is NOT a commit: a lagging server key may leave the old leaf served.
    # Retry reloads within one bounded window, never report that as success.
    while True:
        public.assert_projection(client.config)
        try:
            client.reload()
            verify_served(client.config, public, deadline)
            return
        except (ServedCertificateError, ApiTransportError, JmapSetError) as error:
            retry_pause(deadline, error)


def reconcile(client: JmapClient, public: PublicCertificate, deadline: float) -> str:
    config = client.config
    identifier = client.default_id()
    record = client.certificate(identifier) if identifier is not None else None
    if record is not None:
        assert_managed(record, public, config)
    public.assert_projection(config)
    modified = False
    if record is None:
        # API errors and ambiguous get results never reach this branch.
        assert_default(client, identifier)
        public.assert_projection(config)
        new_identifier = client.matching_certificate(public)
        if new_identifier is None:
            created = client.create(
                "x:Certificate/set", "tls",
                {
                    "certificate": {"@type": "Text", "value": public.pem},
                    "privateKey": {"@type": "File", "filePath": config.key_path},
                },
            )
            new_identifier = created.get("id")
            if not isinstance(new_identifier, str) or not SAFE_ID.fullmatch(new_identifier):
                raise ApiProtocolError("created_certificate_id_invalid")
        else:
            client.update(
                "x:Certificate/set", new_identifier,
                {"privateKey": {"@type": "File", "filePath": config.key_path}},
            )
        assert_default(client, identifier)
        # Finish linking our newly created record before checking projection
        # drift. A changed projection is reconciled against this same ID rather
        # than creating another orphan on the next attempt; TLS is not reloaded
        # until the post-write projection guard and metadata checks pass.
        client.update(
            "x:SystemSettings/set", "singleton", {"defaultCertificateId": new_identifier}
        )
        identifier = new_identifier
        modified = True
    elif not public.text_matches(record.get("certificate")) or not public.metadata_matches(record):
        assert_default(client, identifier)
        public.assert_projection(config)
        pem = public.pem
        stored = record.get("certificate")
        if isinstance(stored, dict) and stored.get("@type") == "Text" and stored.get("value") == pem:
            # v0.16 recalculates metadata only when the certificate value changes.
            # Whitespace changes no certificate material; chain equality below
            # prevents this repair from causing subsequent redundant writes.
            pem += "\n"
        client.update(
            "x:Certificate/set", identifier,
            {
                "certificate": {"@type": "Text", "value": pem},
                "privateKey": {"@type": "File", "filePath": config.key_path},
            },
        )
        modified = True
    public.assert_projection(config)
    if modified:
        record = client.certificate(identifier)
        if record is None or not public.text_matches(record.get("certificate")):
            raise ApiProtocolError("certificate_update_not_visible")
        if not public.metadata_matches(record):
            raise ApiProtocolError("certificate_metadata_stale")
        assert_default(client, identifier)
        reload_and_verify(client, public, deadline)
    else:
        try:
            verify_served(config, public, deadline)
        except ServedCertificateError:
            # This also recovers a stale TLS cache after a Stalwart restart when
            # the stored certificate already matches and needs no API write.
            reload_and_verify(client, public, deadline)
    public.assert_projection(config)
    assert_default(client, identifier)
    return identifier


def synchronize(config: Config) -> tuple[str, PublicCertificate]:
    deadline = time.monotonic() + RECONCILE_TIMEOUT
    while True:
        try:
            public = PublicCertificate.load(config)
            # Mounts are re-read each cycle (and after projection races), so
            # ExternalSecret credential rotation requires no sidecar restart.
            client = JmapClient(config, deadline)
            identifier = reconcile(client, public, deadline)
            return identifier, public
        except ProjectionChanged as error:
            retry_pause(deadline, error)


def cycle(config: Config) -> bool:
    try:
        identifier, public = synchronize(config)
        expiry = datetime.fromtimestamp(public.not_after, timezone.utc).isoformat().replace("+00:00", "Z")
        fingerprint = hashlib.sha256(public.chain[0]).hexdigest()
        print(
            f"sync_ok certificate_id={identifier} sha256={fingerprint} expires={expiry}",
            flush=True,
        )
        return True
    except SyncError as error:
        print(f"sync_failed category={error.category}", file=sys.stderr, flush=True)
    except Exception:
        # Never print exception representations, HTTP payloads, PEM, or tokens.
        print("sync_failed category=unexpected_error", file=sys.stderr, flush=True)
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="Run one bounded reconciliation cycle.")
    arguments = parser.parse_args()
    try:
        config = Config.from_environment()
    except SyncError as error:
        print(f"sync_failed category={error.category}", file=sys.stderr, flush=True)
        return 2
    if arguments.once:
        return 0 if cycle(config) else 1
    while True:
        cycle(config)
        time.sleep(config.interval)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
