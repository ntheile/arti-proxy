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

NO_ACCEPTABLE_METHODS = b"\x05\xff"
USERNAME_PASSWORD_METHOD = 0x02
AUTH_SUCCESS = b"\x01\x00"
AUTH_FAILURE = b"\x01\x01"


class SocksError(Exception):
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


async def relay(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def handle_client(client_reader, client_writer):
    peer = client_writer.get_extra_info("peername")
    upstream_writer = None
    try:
        await authenticate(client_reader, client_writer)
        request_address = await read_request(client_reader)
        status, upstream_reply, upstream_reader, upstream_writer = await open_upstream(request_address)
        client_writer.write(upstream_reply)
        await client_writer.drain()
        if status != 0:
            raise SocksError(f"upstream connection failed with status {status}")

        await asyncio.gather(
            relay(client_reader, upstream_writer),
            relay(upstream_reader, client_writer),
        )
    except Exception as exc:
        print(f"SOCKS connection from {peer} closed: {exc}", file=sys.stderr, flush=True)
    finally:
        if upstream_writer:
            upstream_writer.close()
        client_writer.close()


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
