# ZigZag
A minimal HTTP server written in Zig.

Currently a toy project and insecure.

# Todo
- [x] Shutdown server nicely when C-c
- [x] Sanitize request when serving directories
- [x] Comments and docstrings
- [x] Event driven architecture for conqurrent connectinos/requests
- [x] Support query parameters
- [x] Support for all HTTP methods
- [x] Support path parameters
    - [ ] Creaet a comptime struct for path parameters (currently uses hash map)
- [x] Support for all response codes
- [x] Keep HTTP connection open when requested
- [ ] Allow string to be returned from endpoints
- [ ] Automatically configure headers for the response
- [ ] Support for streaming the response (right now response generation hangs the event loop)
- [ ] Do gracefull shutdown
- [ ] Create a utils file to move some of the functions
- [ ] Middleware support
- [ ] Performance benchmarking
- [ ] Provide build file
- [ ] MAYBE default handler for HEAD requests
- [ ] MAYBE default handler for OPTIONS requests
- [ ] MAYBE use enum (or tagged union) for headers
- [ ] MAYBE Support state injection to endpoints (doesn't feel neccessery in Zig)
