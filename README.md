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
- [ ] Support state injection to endpoints
- [x] Support path parameters
    - [ ] Creaet a comptime struct for path parameters (currently uses string hash map)
- [x] Support for all response codes
- [ ] Allow string to be returned from endpoints
- [ ] Automatically configure headers for the response
- [ ] Support compression
- [ ] Support for streaming the response (right now response generation hangs the event loop)
- [ ] Do gracefull shutdown
- [ ] Create a utils file to move some of the functions
- [x] Keep HTTP connection open when requested
- [ ] Performance benchmarking
- [ ] MAYBE automatically handle HEAD
- [ ] MAYBE automatically handle OPTIONS
