# OSIRIS Lab Infrastructure Team Tutorial

Hands-on infrastructure exercises for the OSIRIS Lab Infrastructure Team.

## Task 1: Internal Server and Gateway

Set up two Ubuntu containers:

- **Internal server** — connected only to the private network
- **Gateway server** — connected to both the private and external networks

The internal server routes external traffic through the gateway. The gateway uses IP forwarding and NAT (MASQUERADE) to provide external connectivity.

## Test

1. Start only the internal server.
2. Verify that the internal server cannot reach `1.1.1.1`.
3. Start the gateway server.
4. Verify that the same internal server can now reach `1.1.1.1`.

Run the automated test with:

```bash
./test_gateway.sh
```
### GitHub Actions Note

GitHub-hosted runners do not reliably support outbound ICMP (`ping`). Therefore, the automated CI test uses HTTPS with `curl` instead of `ping`.

The same connectivity test is used before and after starting the gateway:

1. With the gateway **off**, HTTPS access from the internal server must fail.
2. With the gateway **on**, the same HTTPS request must succeed.

This verifies that external connectivity is provided through the gateway while keeping the CI test compatible with GitHub-hosted runners.
