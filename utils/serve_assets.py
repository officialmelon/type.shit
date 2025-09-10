import http.server
import socketserver
import os

PORT = 8090
PUBLIC_DIR = os.path.join(os.path.dirname(__file__), '..', 'public')

class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        # Serve files from the assets directory
        rel_path = path.lstrip('/')
        return os.path.join(PUBLIC_DIR, rel_path)

if __name__ == "__main__":
    os.chdir(PUBLIC_DIR)
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        print(f"Serving assets at http://localhost:{PORT}/")
        httpd.serve_forever()
