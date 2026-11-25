using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace Ftoons {
    // A loopback-only static host for the flat Godot export. Each connection
    // gets a worker because browsers can open speculative connections.
    public static class LocalWebHost {
        private static readonly Dictionary<string,string> Types = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase) {
            { ".html", "text/html; charset=utf-8" }, { ".js", "text/javascript; charset=utf-8" },
            { ".wasm", "application/wasm" }, { ".pck", "application/octet-stream" }, { ".png", "image/png" },
            { ".txt", "text/plain; charset=utf-8" }, { ".json", "application/json" }, { ".zip", "application/zip" }
        };

        public static void Serve(TcpClient client, string root) {
            ThreadPool.QueueUserWorkItem(delegate {
                using (client) {
                    client.ReceiveTimeout = 5000;
                    client.SendTimeout = 15000;
                    try {
                        using (NetworkStream stream = client.GetStream()) {
                            byte[] buffer = new byte[16384];
                            int length = 0;
                            string headers = "";
                            while (!headers.Contains("\r\n\r\n")) {
                                if (length == buffer.Length) { Headers(stream, "431 Request Header Fields Too Large", "text/plain", 0); return; }
                                int count = stream.Read(buffer, length, buffer.Length - length);
                                if (count == 0) return;
                                length += count;
                                headers = Encoding.ASCII.GetString(buffer, 0, length);
                            }
                            string[] request = headers.Substring(0, headers.IndexOf("\r\n", StringComparison.Ordinal)).Split(' ');
                            if (request.Length != 3 || (request[0] != "GET" && request[0] != "HEAD")) {
                                Headers(stream, "405 Method Not Allowed", "text/plain", 0);
                                return;
                            }
                            string path = request[1].Split('?')[0];
                            if (path == "/_ftoons_health") {
                                byte[] health = Encoding.UTF8.GetBytes("ftoons-production " + root);
                                Headers(stream, "200 OK", "text/plain; charset=utf-8", health.Length);
                                if (request[0] == "GET") stream.Write(health, 0, health.Length);
                                return;
                            }
                            if (path == "/") path = "/index.html";
                            if (!Regex.IsMatch(path, "^/[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$")) {
                                Headers(stream, "404 Not Found", "text/plain", 0);
                                return;
                            }
                            string file = Path.Combine(root, path.Substring(1));
                            if (!File.Exists(file)) { Headers(stream, "404 Not Found", "text/plain", 0); return; }
                            using (FileStream body = File.OpenRead(file)) {
                                string type;
                                if (!Types.TryGetValue(Path.GetExtension(file), out type)) type = "application/octet-stream";
                                Headers(stream, "200 OK", type, body.Length);
                                if (request[0] == "GET") body.CopyTo(stream);
                            }
                        }
                    } catch (IOException) { /* Browser disconnected or timed out. */ }
                      catch (SocketException) { /* Browser disconnected. */ }
                }
            });
        }

        private static void Headers(Stream stream, string status, string type, long length) {
            string header = "HTTP/1.1 " + status + "\r\nContent-Type: " + type + "\r\nContent-Length: " + length
                + "\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
            byte[] bytes = Encoding.ASCII.GetBytes(header);
            stream.Write(bytes, 0, bytes.Length);
        }
    }
}
