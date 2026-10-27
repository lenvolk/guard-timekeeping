"""Signature images in Azure Blob Storage, reached with the API's managed identity.

The storage account rejects account keys, so every call uses a Microsoft Entra token.
"""

from __future__ import annotations

import base64
import binascii
import logging
import os
import threading
from datetime import datetime, timezone

from azure.core.exceptions import AzureError, ResourceNotFoundError
from azure.storage.blob import BlobServiceClient, ContainerClient, ContentSettings

import db

log = logging.getLogger("timekeeping.signatures")

MAX_SIGNATURE_BYTES = 200 * 1024
DATA_URL_PREFIX = "data:image/png;base64,"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

_container: ContainerClient | None = None
_container_lock = threading.Lock()


class SignatureInvalid(ValueError):
    """The signature is missing or is not an acceptable PNG."""


class StorageUnavailable(RuntimeError):
    """Blob Storage refused or failed the request."""


def _get_container() -> ContainerClient:
    global _container
    with _container_lock:
        if _container is None:
            url = os.environ.get("STORAGE_BLOB_URL")
            if not url:
                raise StorageUnavailable("The STORAGE_BLOB_URL app setting is missing.")
            service = BlobServiceClient(url, credential=db.get_credential())
            _container = service.get_container_client(os.environ.get("SIGNATURE_CONTAINER", "signatures"))
        return _container


def decode(data_url: str | None) -> bytes:
    """Turn the PNG data URL from the signature pad into bytes, or raise SignatureInvalid."""
    if not data_url or not data_url.strip():
        raise SignatureInvalid("A signature is required. Sign in the box, then submit again.")
    data_url = data_url.strip()
    if not data_url.startswith(DATA_URL_PREFIX):
        raise SignatureInvalid("The signature must be a PNG image.")
    encoded = data_url[len(DATA_URL_PREFIX):]
    # Check the length before decoding, so a huge field never reaches memory twice.
    if len(encoded) > (MAX_SIGNATURE_BYTES * 4) // 3 + 4:
        raise SignatureInvalid("The signature image is larger than 200 KB.")
    try:
        image = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise SignatureInvalid("The signature is not valid base64 data.")
    if not image.startswith(PNG_MAGIC):
        raise SignatureInvalid("The signature must be a PNG image.")
    if len(image) > MAX_SIGNATURE_BYTES:
        raise SignatureInvalid("The signature image is larger than 200 KB.")
    return image


def blob_name(site_id: int, occurred_at: datetime, event_id: int) -> str:
    """<site_id>/<yyyy>/<mm>/<dd>/<event_id>.png, using the UTC date."""
    when = occurred_at.astimezone(timezone.utc)
    return f"{site_id}/{when:%Y}/{when:%m}/{when:%d}/{event_id}.png"


def upload(name: str, image: bytes) -> None:
    try:
        _get_container().upload_blob(
            name,
            image,
            overwrite=True,
            content_settings=ContentSettings(content_type="image/png"),
        )
    except AzureError as exc:
        log.exception("Uploading signature %s failed.", name)
        raise StorageUnavailable(type(exc).__name__) from exc


def delete_quietly(name: str) -> None:
    """Remove a blob whose database transaction failed. Logs instead of raising."""
    try:
        _get_container().delete_blob(name)
    except AzureError:
        log.exception("Could not delete orphaned signature %s.", name)


def download(name: str) -> bytes | None:
    try:
        return _get_container().download_blob(name).readall()
    except ResourceNotFoundError:
        return None
    except AzureError as exc:
        log.exception("Downloading signature %s failed.", name)
        raise StorageUnavailable(type(exc).__name__) from exc


def check() -> None:
    """List one blob to prove the identity can read the container. Raises StorageUnavailable."""
    try:
        for _ in _get_container().list_blobs(results_per_page=1):
            break
    except AzureError as exc:
        raise StorageUnavailable(type(exc).__name__) from exc


def delete_all() -> int:
    """Delete every signature in the container and return how many. Raises StorageUnavailable."""
    container = _get_container()
    deleted = 0
    try:
        for blob in container.list_blobs():
            container.delete_blob(blob.name)
            deleted += 1
    except AzureError as exc:
        log.exception("Deleting signatures failed after %s blobs.", deleted)
        raise StorageUnavailable(type(exc).__name__) from exc
    return deleted
