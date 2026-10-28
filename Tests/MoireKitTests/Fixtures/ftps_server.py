"""A small FTP server for tests, speaking plain FTP, explicit TLS (AUTH TLS) and implicit TLS.

It serves one folder read-only, so the real curl that Moire runs can be tested end to end.
Usage: python3 -I ftps_server.py ROOT CERT KEY PASSWORD
Prints "ready <plain port> <implicit TLS port>" once both are listening.
"""
import os
import socket
import ssl
import sys
import threading
import time

ROOT, CERT, KEY, PASSWORD = sys.argv[1:5]
CONTEXT = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CONTEXT.load_cert_chain(CERT, KEY)


def facts(path):
    st = os.lstat(path)
    kind = "dir" if os.path.isdir(path) else "file"
    modify = time.strftime("%Y%m%d%H%M%S", time.gmtime(st.st_mtime))
    return f"type={kind};size={st.st_size};modify={modify};"


class Session(threading.Thread):
    def __init__(self, conn, implicit):
        super().__init__(daemon=True)
        self.conn = conn
        self.protect = False
        self.cwd = "/"
        self.user = None
        self.logged_in = False
        self.passive = None
        self.offset = 0
        if implicit:
            self.conn = CONTEXT.wrap_socket(conn, server_side=True)
            self.protect = True
        self.file = self.conn.makefile("rb")

    def send(self, line):
        self.conn.sendall((line + "\r\n").encode("utf-8"))

    def real(self, path):
        joined = os.path.normpath(os.path.join(self.cwd, path or ""))
        full = os.path.normpath(os.path.join(ROOT, joined.lstrip("/")))
        if not (full == ROOT or full.startswith(ROOT + os.sep)):
            raise PermissionError(path)
        return full

    def open_passive(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        self.passive = listener
        return listener.getsockname()[1]

    def data(self):
        conn, _ = self.passive.accept()
        self.passive.close()
        self.passive = None
        return CONTEXT.wrap_socket(conn, server_side=True) if self.protect else conn

    def run(self):
        self.send("220 Moire test server")
        while True:
            raw = self.file.readline()
            if not raw:
                return
            line = raw.decode("utf-8").rstrip("\r\n")
            command, _, argument = line.partition(" ")
            command = command.upper()
            try:
                if not self.handle(command, argument):
                    return
            except (FileNotFoundError, PermissionError, NotADirectoryError):
                self.send("550 Not found")

    def handle(self, command, argument):
        if command == "AUTH" and argument.upper() in ("TLS", "SSL"):
            self.send("234 Go ahead")
            self.conn = CONTEXT.wrap_socket(self.conn, server_side=True)
            self.file = self.conn.makefile("rb")
        elif command == "PBSZ":
            self.send("200 PBSZ=0")
        elif command == "PROT":
            self.protect = argument.upper() == "P"
            self.send("200 OK")
        elif command == "USER":
            self.user = argument
            self.send("331 Password")
        elif command == "PASS":
            self.logged_in = self.user == "moire" and argument == PASSWORD
            self.send("230 Logged in" if self.logged_in else "530 Login incorrect")
        elif not self.logged_in and command not in ("QUIT", "FEAT", "SYST"):
            self.send("530 Log in first")
        elif command == "QUIT":
            self.send("221 Bye")
            return False
        elif command == "SYST":
            self.send("215 UNIX Type: L8")
        elif command == "FEAT":
            self.send("211-Features")
            for feature in ("MLST type*;size*;modify*;", "SIZE", "MDTM", "REST STREAM", "EPSV", "UTF8", "AUTH TLS", "PBSZ", "PROT"):
                self.send(" " + feature)
            self.send("211 End")
        elif command in ("OPTS", "TYPE", "MODE", "STRU", "NOOP"):
            self.send("200 OK")
        elif command == "PWD":
            self.send(f'257 "{self.cwd}"')
        elif command == "CWD":
            target = self.real(argument)
            if not os.path.isdir(target):
                raise NotADirectoryError(argument)
            self.cwd = "/" + os.path.relpath(target, ROOT) if target != ROOT else "/"
            self.send("250 OK")
        elif command == "EPSV":
            self.send(f"229 Entering Extended Passive Mode (|||{self.open_passive()}|)")
        elif command == "PASV":
            port = self.open_passive()
            self.send(f"227 Entering Passive Mode (127,0,0,1,{port >> 8},{port & 255})")
        elif command == "SIZE":
            self.send(f"213 {os.path.getsize(self.real(argument))}")
        elif command == "MDTM":
            self.send("213 " + time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(self.real(argument)))))
        elif command == "REST":
            self.offset = int(argument)
            self.send("350 Restarting")
        elif command == "MLSD":
            folder = self.real(argument)
            names = sorted(os.listdir(folder))
            self.send("150 Listing")
            data = self.data()
            for name in names:
                data.sendall((facts(os.path.join(folder, name)) + " " + name + "\r\n").encode("utf-8"))
            self.close(data)
            self.send("226 Done")
        elif command == "RETR":
            path = self.real(argument)
            self.send("150 Sending")
            data = self.data()
            with open(path, "rb") as handle:
                handle.seek(self.offset)
                self.offset = 0
                while True:
                    chunk = handle.read(65536)
                    if not chunk:
                        break
                    try:
                        data.sendall(chunk)
                    except OSError:
                        # curl closes the data connection once a byte range is complete.
                        break
            self.close(data)
            self.send("226 Done")
        elif command == "ABOR":
            self.send("226 Aborted")
        else:
            self.send("502 Not implemented")
        return True

    @staticmethod
    def close(data):
        try:
            if isinstance(data, ssl.SSLSocket):
                data.unwrap()
        except (OSError, ssl.SSLError):
            pass
        data.close()


def serve(listener, implicit):
    while True:
        conn, _ = listener.accept()
        Session(conn, implicit).start()


def listen():
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(16)
    return listener


plain, implicit = listen(), listen()
threading.Thread(target=serve, args=(plain, False), daemon=True).start()
threading.Thread(target=serve, args=(implicit, True), daemon=True).start()
print(f"ready {plain.getsockname()[1]} {implicit.getsockname()[1]}", flush=True)
sys.stdin.read()
