#!/usr/bin/env python3
import asyncio
import os
import sys


PUBLIC_SOCKS_HOST = os.environ.get("PUBLIC_SOCKS_HOST", "0.0.0.0")
PUBLIC_SOCKS_PORT = int(os.environ.get("PUBLIC_SOCKS_PORT", "9150"))
UPSTREAM_SOCKS_HOST = os.environ.get("UPSTREAM_SOCKS_HOST", "127.0.0.1")
UPSTREAM_SOCKS_PORT = int(os.environ.get("UPSTREAM_SOCKS_PORT", "9151"))
SOCKS_USERNAME = os.environ.get("SOCKS_USERNAME")
SOCKS_PASSWORD = os.environ.get("SOCKS_PASSWORD")
SOCKS_HANDSHAKE_TIMEOUT = float(os.environ.get("SOCKS_HANDSHAKE_TIMEOUT", "15"))
UPSTREAM_CONNECT_RETRIES = int(os.environ.get("UPSTREAM_CONNECT_RETRIES", "3"))
UPSTREAM_CONNECT_RETRY_DELAY = float(os.environ.get("UPSTREAM_CONNECT_RETRY_DELAY", "1"))

NO_ACCEPTABLE_METHODS = b"\x05\xff"
USERNAME_PASSWORD_METHOD = 0x02
AUTH_SUCCESS = b"\x01\x00"
AUTH_FAILURE = b"\x01\x01"
SOCKS_STATUS_MESSAGES = {
    1: "general SOCKS server failure",
    2: "connection not allowed by ruleset",
    3: "network unreachable",
    4: "host unreachable",
    5: "connection refused",
    6: "ttl expired",
    7: "command not supported",
    8: "address type not supported",
}
RETRYABLE_UPSTREAM_STATUSES = {1, 3, 4, 5, 6}


class SocksError(Exception):
    pass


def upstream_status_message(status):
    return SOCKS_STATUS_MESSAGES.get(status, "unknown failure")


async def close_writer(writer):
    if not writer:
        return
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass


async def read_exactly(reader, size):
    try:
        return await reader.readexactly(size)
    except asyncio.IncompleteReadError as exc:
        raise SocksError("client disconnected") from exc


async def authenticate(reader, writer):
    version_methods = await read_exactly(reader, 2)
    version, method_count = version_methods
    if version != 5:
        raise SocksError("unsupported SOCKS version")

    methods = await read_exactly(reader, method_count)
    if USERNAME_PASSWORD_METHOD not in methods:
        writer.write(NO_ACCEPTABLE_METHODS)
        await writer.drain()
        raise SocksError("client did not offer username/password auth")

    writer.write(bytes([5, USERNAME_PASSWORD_METHOD]))
    await writer.drain()

    auth_version = await read_exactly(reader, 1)
    if auth_version != b"\x01":
        writer.write(AUTH_FAILURE)
        await writer.drain()
        raise SocksError("unsupported auth version")

    username_length = (await read_exactly(reader, 1))[0]
    username = (await read_exactly(reader, username_length)).decode("utf-8", "replace")
    password_length = (await read_exactly(reader, 1))[0]
    password = (await read_exactly(reader, password_length)).decode("utf-8", "replace")

    if username != SOCKS_USERNAME or password != SOCKS_PASSWORD:
        writer.write(AUTH_FAILURE)
        await writer.drain()
        raise SocksError("bad credentials")

    writer.write(AUTH_SUCCESS)
    await writer.drain()


async def read_request(reader):
    header = await read_exactly(reader, 4)
    version, command, reserved, address_type = header
    if version != 5 or reserved != 0:
        raise SocksError("invalid request")
    if command != 1:
        raise SocksError("only CONNECT is supported")

    if address_type == 1:
        address = await read_exactly(reader, 4)
    elif address_type == 3:
        length = await read_exactly(reader, 1)
        address = length + await read_exactly(reader, length[0])
    elif address_type == 4:
        address = await read_exactly(reader, 16)
    else:
        raise SocksError("unsupported address type")

    port = await read_exactly(reader, 2)
    return bytes([address_type]) + address + port


async def open_upstream(request_address):
    reader, writer = await asyncio.open_connection(UPSTREAM_SOCKS_HOST, UPSTREAM_SOCKS_PORT)
    try:
        writer.write(b"\x05\x01\x00")
        await writer.drain()

        response = await read_exactly(reader, 2)
        if response != b"\x05\x00":
            raise SocksError("upstream SOCKS rejected no-auth handshake")

        writer.write(b"\x05\x01\x00" + request_address)
        await writer.drain()

        reply_header = await read_exactly(reader, 4)
        version, status, reserved, address_type = reply_header
        if version != 5 or reserved != 0:
            raise SocksError("invalid upstream reply")

        if address_type == 1:
            bind_address = await read_exactly(reader, 4)
        elif address_type == 3:
            length = await read_exactly(reader, 1)
            bind_address = length + await read_exactly(reader, length[0])
        elif address_type == 4:
            bind_address = await read_exactly(reader, 16)
        else:
            raise SocksError("unsupported upstream bind address type")

        bind_port = await read_exactly(reader, 2)
        return status, reply_header + bind_address + bind_port, reader, writer
    except BaseException:
        await close_writer(writer)
        raise


async def open_upstream_with_retries(request_address):
    last_exc = None
    attempts = max(1, UPSTREAM_CONNECT_RETRIES)
    for attempt in range(1, attempts + 1):
        try:
            status, reply, reader, writer = await open_upstream(request_address)
        except Exception as exc:
            last_exc = exc
            if attempt >= attempts:
                raise
            print(
                f"upstream SOCKS attempt {attempt}/{attempts} failed: {exc}; retrying",
                file=sys.stderr,
                flush=True,
            )
        else:
            if status == 0:
                return status, reply, reader, writer
            if status not in RETRYABLE_UPSTREAM_STATUSES or attempt >= attempts:
                return status, reply, reader, writer
            message = upstream_status_message(status)
            print(
                f"upstream SOCKS attempt {attempt}/{attempts} failed with status {status} ({message}); retrying",
                file=sys.stderr,
                flush=True,
            )
            await close_writer(writer)

        await asyncio.sleep(UPSTREAM_CONNECT_RETRY_DELAY)

    raise last_exc or SocksError("upstream SOCKS connection failed")


async def relay(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        await close_writer(writer)


async def handle_client(client_reader, client_writer):
    peer = client_writer.get_extra_info("peername")
    upstream_writer = None
    try:
        async with asyncio.timeout(SOCKS_HANDSHAKE_TIMEOUT):
            await authenticate(client_reader, client_writer)
            request_address = await read_request(client_reader)
            status, upstream_reply, upstream_reader, upstream_writer = await open_upstream_with_retries(request_address)
        client_writer.write(upstream_reply)
        await client_writer.drain()
        if status != 0:
            message = upstream_status_message(status)
            raise SocksError(f"upstream connection failed with status {status} ({message})")

        await asyncio.gather(
            relay(client_reader, upstream_writer),
            relay(upstream_reader, client_writer),
        )
    except TimeoutError:
        print(f"SOCKS connection from {peer} closed: handshake timed out", file=sys.stderr, flush=True)
    except Exception as exc:
        print(f"SOCKS connection from {peer} closed: {exc}", file=sys.stderr, flush=True)
    finally:
        await close_writer(upstream_writer)
        await close_writer(client_writer)


async def main():
    if not SOCKS_USERNAME or not SOCKS_PASSWORD:
        print("SOCKS_USERNAME and SOCKS_PASSWORD are required", file=sys.stderr)
        return 1

    if len(SOCKS_USERNAME.encode("utf-8")) > 255 or len(SOCKS_PASSWORD.encode("utf-8")) > 255:
        print("SOCKS_USERNAME and SOCKS_PASSWORD must each be 255 bytes or less", file=sys.stderr)
        return 1

    server = await asyncio.start_server(handle_client, PUBLIC_SOCKS_HOST, PUBLIC_SOCKS_PORT)
    sockets = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
    print(f"Authenticated SOCKS5 proxy listening on {sockets}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        raise SystemExit(asyncio.run(main()))
    except KeyboardInterrupt:
        pass
