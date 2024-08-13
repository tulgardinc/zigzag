# ZigZag
A minimal HTTP server written in Zig.

Currently a toy project and insecure.

# Todo
- [x] Shutdown server nicely when C-c
- [x] Sanitize request when serving directories
- [x] Comments and docstrings
- [ ] Multithreading
- [ ] Support for all HTTP methods
- [ ] Support state injection to endpoints
- [ ] Support route parameters
- [ ] Support for all response codes
- [ ] Automatically configure headers for the response
- [ ] Support compression
- [ ] Keep HTTP connection open when requested
