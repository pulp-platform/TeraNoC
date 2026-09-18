#!/usr/bin/env python3
"""Parallel telemetry ingest.

Reading the trace is the dominant cost of generating a dashboard: for a 17M
record capture, json.loads and validate() are together about 90% of it, and both
are pure per-row functions. This splits the decoded stream into line-aligned
chunks and decodes them in worker processes, while the parent keeps the parts
that must stay sequential: reading, the source digest, and the order in which
decoded batches are appended to the cache.

The cache bytes this produces are identical to the sequential path, so only the
time changes, never the dashboard.
"""
import gzip
import io
import json
import pickle

from .model import identity, validate

BATCH = 1024


def _decode(line, line_number, cutoff, bounds):
    """One line to a row, or None when it is filtered out; meta rows pass through."""
    row = json.loads(line)
    if row.get("kind") == "meta":
        if row.get("schema_version", 1) != 1:
            raise ValueError("unsupported schema_version")
        return row
    if row.get("kind") == "link" and isinstance(row.get("network"), str):
        row["network"] = row["network"].strip()
    validate(row)
    row["source_line"] = line_number
    row["origin"] = "telemetry"
    if cutoff is not None and row["end"] > cutoff:
        return None
    if bounds is not None and not (row["end"] > bounds[0] and row["start"] < bounds[1]):
        return None
    return row


def parse_chunk(task):
    """Decode one chunk; returns the cache bytes, the identities and any headers.

    Runs in a worker process, so it takes and returns only picklable values and
    reports errors with the same path:line prefix as the sequential reader.
    """
    path, first_line, blob, cutoff, bounds = task
    out, batch, ids, headers = io.BytesIO(), [], set(), []
    number = first_line
    for line in blob.splitlines(keepends=True):
        if line.strip():
            try:
                row = _decode(line, number, cutoff, bounds)
            except (ValueError, TypeError, KeyError) as error:
                raise ValueError(f"{path}:{number}: {error}") from error
            if row is not None:
                if row.get("kind") == "meta":
                    headers.append(row)
                else:
                    ids.add(identity(row))
                    batch.append(row)
                    if len(batch) >= BATCH:
                        pickle.dump(batch, out, protocol=pickle.HIGHEST_PROTOCOL)
                        batch = []
        number += 1
    if batch:
        pickle.dump(batch, out, protocol=pickle.HIGHEST_PROTOCOL)
    return out.getvalue(), ids, headers, number


def chunks(path, digest, target=4 << 20):
    """Yield (first_line, blob) pairs split on line boundaries, hashing as we read."""
    opener = gzip.open if str(path).endswith(".gz") else open
    line_number, buffer, size = 1, [], 0
    with opener(path, "rb") as stream:
        for line in stream:
            digest.update(line)
            buffer.append(line)
            size += len(line)
            if size >= target:
                blob = b"".join(buffer)
                yield line_number, blob
                line_number += len(buffer)
                buffer, size = [], 0
    if buffer:
        yield line_number, b"".join(buffer)
