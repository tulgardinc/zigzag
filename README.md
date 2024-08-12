# ZigZag
A minimal HTTP server written in Zig.

Currently a toy project and insecure.

# Todo
- [ ] Shutdown server nicely when C-c
- [ ] Sanitize request when serving directories
- [ ] Comments and docstrings
- [ ] Multithreading
- [ ] Support for all HTTP methods
- [ ] Support state injection to endpoints
- [ ] Support route parameters
- [ ] Handle HTTP errors as zig erros from endpoints
- [ ] Support for all response codes
- [ ] Automatically configure headers for the response
- [ ] Support compression
- [ ] Keep HTTP connection open when requested
