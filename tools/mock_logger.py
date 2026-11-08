#!/usr/bin/env python3
"""
Simulador de logger Solarman V5 + microinversor Deye SUN-M G4 (4 MPPT).

Sirve para probar la app sin tener el micro delante (o de noche, cuando el
micro está apagado). Arráncalo en tu PC y en la app pon la IP del PC,
puerto 8899 y el número de serie que indiques aquí.

    python3 mock_logger.py --serial 2712345678 --port 8899

Implementa Modbus 0x03 (leer holding), 0x06 (escribir uno) y 0x10
(escribir varios). Los valores escritos se guardan en memoria.
"""
import argparse
import math
import random
import socket
import socketserver
import struct
import threading
import time


def crc16(data: bytes) -> bytes:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return struct.pack("<H", crc)


def v5_checksum(frame: bytes) -> int:
    return sum(frame[1:-2]) & 0xFF


class Inverter:
    """Mapa de registros (holding) de un Deye SUN-M G4 de 4 MPPT."""

    def __init__(self):
        self.lock = threading.Lock()
        self.regs = [0] * 256
        r = self.regs
        r[0] = 0x0400            # tipo de dispositivo: microinversor
        r[1] = 1                 # dirección modbus
        sn = b"2405123456"       # nº de serie del micro (10 ASCII)
        for i in range(5):
            r[3 + i] = (sn[2 * i] << 8) | sn[2 * i + 1]
        rated = 20000            # 2000.0 W (x0.1), U32 palabra baja primero
        r[16], r[17] = rated & 0xFFFF, rated >> 16
        r[18] = 0x0401           # 4 MPPT, 1 fase
        r[40] = 1000             # límite de potencia activa: 100.0 % (x0.1)
        r[43] = 1                # 1 = encendido, 2 = apagado
        r[59] = 2                # estado: normal
        self.total = [12345, 3100, 3080, 3090, 3075]  # x0.1 kWh
        self.today = [0, 0, 0, 0, 0]
        self.update()

    def update(self):
        with self.lock:
            r = self.regs
            on = r[43] == 1
            limit_pct = (r[40] / 10.0) if r[40] > 120 else float(r[40])
            t = time.time()
            sun = max(0.0, math.sin(t / 60.0) * 0.4 + 0.6)  # oscila cada pocos minutos
            total_p = 0.0
            for i in range(4):
                v = 38.0 + random.uniform(-0.6, 0.6) if on else 44.0
                a = (10.5 * sun * min(1.0, limit_pct / 100.0) + random.uniform(-0.2, 0.2)) if on else 0.0
                a = max(0.0, a)
                r[109 + 2 * i] = int(v * 10)
                r[110 + 2 * i] = int(a * 10)
                total_p += v * a
            ac = total_p * 0.96
            r[86], r[87] = int(ac * 10) & 0xFFFF, int(ac * 10) >> 16
            r[73] = int((230 + random.uniform(-2, 2)) * 10)
            cur = int(ac / 230.0 * 10)
            r[76] = cur & 0xFFFF
            r[79] = int((50 + random.uniform(-0.03, 0.03)) * 100)
            r[90] = int(41.5 / 0.01 + 1000)  # (raw - 1000) * 0.01 = 41.5 °C
            r[59] = 2 if on else 0
            for i in range(5):
                self.today[i] = min(self.today[i] + (1 if on else 0), 65535)
            r[60] = self.today[0]
            for i in range(4):
                r[65 + i] = self.today[i + 1]
            for idx, reg in enumerate([63, 69, 71, 74, 77]):
                val = self.total[idx] + self.today[idx]
                r[reg], r[reg + 1] = val & 0xFFFF, val >> 16

    def read(self, addr, qty):
        with self.lock:
            return self.regs[addr:addr + qty]

    def write(self, addr, values):
        with self.lock:
            for i, v in enumerate(values):
                self.regs[addr + i] = v
        print(f"  escrito: reg {addr} = {values}")


def handle_modbus(inv: Inverter, req: bytes) -> bytes:
    if len(req) < 4 or crc16(req[:-2]) != req[-2:]:
        return b""
    slave, fc = req[0], req[1]
    try:
        if fc == 0x03:
            addr, qty = struct.unpack(">HH", req[2:6])
            if qty < 1 or qty > 125 or addr + qty > 256:
                raise ValueError(2)
            vals = inv.read(addr, qty)
            body = bytes([slave, fc, qty * 2]) + b"".join(struct.pack(">H", v) for v in vals)
        elif fc == 0x06:
            addr, val = struct.unpack(">HH", req[2:6])
            inv.write(addr, [val])
            body = req[:6]
        elif fc == 0x10:
            addr, qty, bc = struct.unpack(">HHB", req[2:7])
            vals = list(struct.unpack(">" + "H" * qty, req[7:7 + bc]))
            inv.write(addr, vals)
            body = req[:6]
        else:
            raise ValueError(1)
    except ValueError as e:
        body = bytes([slave, fc | 0x80, int(e.args[0])])
    return body + crc16(body)


def build_response(serial: int, seq: int, modbus: bytes) -> bytes:
    payload = bytes([0x02, 0x01]) + struct.pack("<III", 0, 0, 0) + modbus
    header = b"\xA5" + struct.pack("<HH", len(payload), 0x1510) + bytes([seq, 0x00]) + struct.pack("<I", serial)
    frame = bytearray(header + payload + b"\x00\x15")
    frame[-2] = v5_checksum(frame)
    return bytes(frame)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        srv = self.server
        print(f"Conexión de {self.client_address[0]}")
        buf = b""
        self.request.settimeout(120)
        try:
            while True:
                data = self.request.recv(2048)
                if not data:
                    break
                buf += data
                while len(buf) >= 3:
                    if buf[0] != 0xA5:
                        buf = buf[1:]
                        continue
                    (ln,) = struct.unpack("<H", buf[1:3])
                    total = 13 + ln
                    if len(buf) < total:
                        break
                    frame, buf = buf[:total], buf[total:]
                    if frame[-1] != 0x15 or frame[-2] != v5_checksum(frame):
                        print("  trama V5 inválida")
                        continue
                    (serial,) = struct.unpack("<I", frame[7:11])
                    if serial != srv.serial:
                        print(f"  nº de serie incorrecto: {serial}")
                        continue
                    seq = frame[5]
                    srv.inv.update()
                    mb = handle_modbus(srv.inv, frame[26:-2])
                    self.request.sendall(build_response(srv.serial, seq, mb))
        except (socket.timeout, ConnectionResetError):
            pass
        print("Conexión cerrada")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", type=int, default=2712345678)
    ap.add_argument("--port", type=int, default=8899)
    args = ap.parse_args()
    srv = Server(("0.0.0.0", args.port), Handler)
    srv.serial = args.serial
    srv.inv = Inverter()
    print(f"Logger simulado en puerto {args.port}, nº de serie {args.serial}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
